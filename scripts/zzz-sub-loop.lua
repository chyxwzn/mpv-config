-- zzz-sub-loop 2.0 — 字幕循环学习
-- 基于 subtitle-lines (https://github.com/christoph-heinrich/mpv-subtitle-lines)
-- 核心改进：用 sub-start 属性变化检测字幕结束，实现精准同步（不再依赖 playback-time + buffer）
--
-- Usage:
--   Ctrl+M        打开字幕循环学习面板
--   Ctrl+Shift+L  循环当前字幕
--   Ctrl+Shift+1~9 设置重复次数
--   Ctrl+Shift+A  自动跳转开关
--   Ctrl+Shift+→/← 下一句/上一句

local mp = require 'mp'
local utils = require 'mp.utils'
local script_name = mp.get_script_name()

local SUB_SEEK_OFFSET = 0.01

-- ===== 循环功能状态 =====
local loop_state = {
    active = false,
    loop_sub_index = nil,
    target_start = nil,       -- 循环字幕的 sub-start 值（用于精确匹配）
    loop_count = 0,
    repeat_count = 3,         -- 默认循环 3 次
    auto_advance = true,
    seeking = false,          -- seek 过渡期保护，防止 sub-start 变化误触发
    sub_loop = {},            -- [index] = true 标记哪些句设置了循环
    is_infinite = false,      -- 当前循环是否为无限模式
}

-- ===== 工具函数 =====

local function osd(msg, dur)
    -- 使用 mpv 内置 show-text；osd-align-x=left 让消息靠左（与右侧菜单对称）
    mp.set_property('osd-align-x', 'left')
    mp.set_property('osd-margin-x', '20')
    mp.commandv('show-text', msg, tostring((dur or 3) * 1000))
end

local function trunc(s, n)
    s = s or ''
    if #s > n then return s:sub(1, n) .. '...' end
    return s
end

local function split(str, pat, plain)
    local init = 1
    local r, i, find, sub = {}, 1, string.find, string.sub
    repeat
        local f0, f1 = find(str, pat, init, plain)
        r[i], i = sub(str, init, f0 and f0 - 1), i + 1
        init = f0 and f1 + 1 or 0
    until f0 == nil
    return r
end

-- ===== 循环控制 =====

local function begin_loop(index, subtitles, is_infinite)
    local sub = subtitles[index]
    if not sub then return end

    loop_state.active = true
    loop_state.loop_sub_index = index
    loop_state.target_start = sub.start
    loop_state.loop_count = 0
    loop_state.seeking = true   -- 接下来的 seek 过渡期需要保护
    loop_state.is_infinite = is_infinite or (loop_state.repeat_count == 0)

    -- 先 seek 到字幕起始位置（精准跳转）
    mp.commandv('seek', tostring(sub.start), 'absolute+exact')

    mp.msg.info(string.format('[LOOP_DEBUG] begin_loop idx=%d start=%.2f stop=%.2f repeat=%d infinite=%s',
        index, sub.start, sub.stop, loop_state.repeat_count, tostring(loop_state.is_infinite)))

    -- 延迟清除 seeking 保护（等待 seek 完成后 sub-start 稳定到 target_start）
    local captured_start = sub.start  -- 捕获局部值防止并发修改
    mp.add_timeout(0.5, function()
        if not loop_state.active then return end  -- 循环已被取消
        -- 验证 seek 是否到达目标
        local current_sub_start = mp.get_property_number('sub-start')
        if current_sub_start and math.abs(current_sub_start - captured_start) < 0.01 then
            loop_state.seeking = false
            mp.msg.info('[LOOP_DEBUG] seeking guard cleared, sub-start settled at target')
        else
            -- 如果 sub-start 还没稳定，再等一会儿
            mp.msg.info(string.format('[LOOP_DEBUG] sub-start not settled yet (current=%.2f target=%.2f), retrying',
                current_sub_start or -1, captured_start))
            mp.add_timeout(0.5, function()
                if loop_state.active then loop_state.seeking = false end
                mp.msg.info('[LOOP_DEBUG] seeking guard cleared (forced)')
            end)
        end
    end)
end

local function end_loop()
    loop_state.active = false
    loop_state.loop_sub_index = nil
    loop_state.target_start = nil
    loop_state.loop_count = 0
    loop_state.seeking = false
    loop_state.is_infinite = false
end

local function find_current_sub_index(subtitles)
    if not subtitles then return nil end
    local time = mp.get_property_number('time-pos', 0)
    if not time then return nil end
    local last_started = nil
    for i, sub in ipairs(subtitles) do
        if sub.start <= time + SUB_SEEK_OFFSET then
            last_started = i
        end
    end
    return last_started
end

-- ===== 字幕提取 (来自 subtitle-lines.lua) =====

local sub_strings_available = {
    primary = {
        text = 'sub-text',
        start = 'sub-start',
        ['end'] = 'sub-end',
        visibility = 'sub-visibility',
        delay = 'sub-delay',
        step = 'primary',
        title = '字幕循环学习',
    },
    secondary = {
        text = 'secondary-sub-text',
        start = 'secondary-sub-start',
        ['end'] = 'secondary-sub-end',
        visibility = 'secondary-sub-visibility',
        delay = 'secondary-sub-delay',
        step = 'secondary',
        title = '次字幕循环学习',
    }
}

local sub_strings = sub_strings_available.primary

local function get_current_subtitle_lines()
    local start = mp.get_property_number(sub_strings.start)
    local stop = mp.get_property_number(sub_strings['end'])
    local text = mp.get_property(sub_strings.text)
    local lines = text and text:match('^[%s\n]*(.-)[%s\n]*$') or ''
    return start, stop, text, split(lines, '%s*\n%s*', false)
end

local function same_time(t1, t2)
    return math.abs(t1 - t2) < SUB_SEEK_OFFSET * 2
end

local function merge_subtitle_lines(prev_subs_visible, start, stop, lines)
    for _, subtitle in ipairs(prev_subs_visible) do
        if subtitle.stop >= start or same_time(subtitle.stop, start) then
            for i = #lines, 1, -1 do
                if lines[i] == subtitle.line then
                    table.remove(lines, i)
                    if start < subtitle.start then subtitle.start = start end
                    if stop > subtitle.stop then subtitle.stop = stop end
                end
            end
        end
    end
    return lines
end

local function fix_line_timing(prev_subs_visible, lines, start, prev_start)
    if start == prev_start then
        local start_approx = mp.get_property_number('time-pos', 0) - mp.get_property_number(sub_strings.delay) - SUB_SEEK_OFFSET
        if start_approx - start > 0.1 then
            start = start_approx
        end
    end
    for _, subtitle in ipairs(prev_subs_visible) do
        if subtitle.stop > start then
            local still_visible = false
            for _, line in ipairs(lines) do
                if subtitle.line == line then still_visible = true break end
            end
            if not still_visible then
                subtitle.stop = start
            end
        end
    end
    return start
end

local function acquire_subtitles()
    local sub_delay = mp.get_property_number(sub_strings.delay)
    local sub_visibility = mp.get_property_bool(sub_strings.visibility)
    mp.set_property_bool(sub_strings.visibility, false)

    mp.commandv('set', sub_strings.delay, mp.get_property_number('duration', 0) + 365 * 24 * 60 * 60)
    mp.commandv('sub-step', 1, sub_strings.step)

    local retry_delay = sub_delay
    while true do
        mp.commandv('sub-step', -1, sub_strings.step)
        local delay = mp.get_property_number(sub_strings.delay)
        if retry_delay == delay then break end
        retry_delay = delay
    end

    local subtitles = {}
    local i = 0
    local prev_start, prev_stop, prev_text = -1, -1, nil
    local prev_subs_visible = {}

    retry_delay = nil
    while true do
        local start, stop, text, lines = get_current_subtitle_lines()
        if start and stop and text and (text ~= prev_text or start ~= prev_start or stop ~= prev_stop) then
            for j = #lines, 1, -1 do
                if not lines[j]:find('[^%s]') then table.remove(lines, j) end
            end
            for j = 1, #lines do
                for k = #lines, j + 1, -1 do
                    if lines[j] == lines[k] then table.remove(lines, k) end
                end
            end
            local start_fixed = fix_line_timing(prev_subs_visible, lines, start, prev_start)
            merge_subtitle_lines(prev_subs_visible, start_fixed, stop, lines)
            for j = #prev_subs_visible, 1, -1 do
                if prev_subs_visible[j].stop <= start_fixed then
                    table.remove(prev_subs_visible, j)
                end
            end
            local j = #prev_subs_visible
            for _, line in ipairs(lines) do
                i = i + 1; j = j + 1
                local subtitle = { start = start_fixed, stop = stop, line = line }
                subtitles[i] = subtitle
                prev_subs_visible[j] = subtitle
            end
        else
            local delay = mp.get_property_number(sub_strings.delay)
            if retry_delay == delay then break end
            retry_delay = delay
        end
        prev_start, prev_stop, prev_text = start, stop, text
        mp.commandv('sub-step', 1, sub_strings.step)
    end

    mp.set_property_number(sub_strings.delay, sub_delay)
    mp.set_property_bool(sub_strings.visibility, sub_visibility)

    for _, subtitle in ipairs(subtitles) do
        subtitle.timespan = mp.format_time(subtitle.start) .. '-' .. mp.format_time(subtitle.stop)
    end

    mp.msg.info(string.format('[LOOP_DEBUG] acquire_subtitles 完成，共 %d 句', #subtitles))
    return subtitles
end

-- ===== 菜单显示 =====

local menu_open = false
local subtitles = nil

local function show_loading_indicator()
    local menu = {
        items = { {
            title = 'Loading...',
            icon = 'spinner',
            italic = true,
            muted = true,
            selectable = false,
            value = 'ignore',
        } },
        type = 'subtitle-lines-loading',
        anchor = 'right',
        menu_opacity = 0.35,
    }
    local json = utils.format_json(menu)
    mp.commandv('script-message-to', 'uosc', 'open-menu', json)
end

local function show_subtitle_list(subs)
    local menu = {
        items = {},
        type = 'subtitle-lines-list',
        anchor = 'right',         -- 仅此菜单靠右显示
        menu_opacity = 0.35,      -- 仅此菜单半透明（越低越透）
        callback = { script_name, 'sub-loop-callback' },
        on_close = {
            'script-message-to',
            script_name,
            'uosc-menu-closed',
        }
    }

    local last_started_index = 0
    local last_active_index = nil
    local time = mp.get_property_number('time-pos', 0) + SUB_SEEK_OFFSET

    for i, subtitle in ipairs(subs) do
        local has_started = subtitle.start <= time
        local has_ended = subtitle.stop < time
        local is_active = has_started and not has_ended
        local is_looping = loop_state.active and loop_state.loop_sub_index == i
        local is_sub_loop = loop_state.sub_loop[i]

        -- 标题：循环中的显示进度
        local title = subtitle.line
        if is_looping then
            if loop_state.is_infinite then
                title = string.format('[∞ x%d] %s', loop_state.loop_count + 1, title)
            else
                title = string.format('[%d/%d] %s',
                    math.min(loop_state.loop_count + 1, loop_state.repeat_count),
                    loop_state.repeat_count, title)
            end
        end

        -- 两个按钮：循环 N 次 + 无限 ∞
        -- 当前行正在循环时，对应按钮变为"取消循环"
        local actions = {}
        local is_current_loop = is_sub_loop or is_looping

        -- 按钮1：有限循环 / 取消循环(有限)
        if is_current_loop and not loop_state.is_infinite then
            actions[#actions+1] = {
                name = 'unloop_' .. i,
                icon = 'repeat',
                label = '取消循环',
            }
        elseif loop_state.repeat_count > 0 then
            actions[#actions+1] = {
                name = 'loop_' .. i,
                icon = 'repeat',
                label = '循环 x' .. loop_state.repeat_count,
            }
        end

        -- 按钮2：无限循环 / 取消循环(无限)
        if is_current_loop and loop_state.is_infinite then
            actions[#actions+1] = {
                name = 'unloop_' .. i,
                icon = 'repeat_one',
                label = '取消循环',
            }
        else
            actions[#actions+1] = {
                name = 'infinite_' .. i,
                icon = 'repeat_one',
                label = '无限 ∞',
            }
        end

        menu.items[i] = {
            title = title,
            hint = subtitle.timespan,
            active = is_active,
            value = 'seek_' .. i,
            actions = actions,
            actions_place = 'inside',
            keep_open = true,
        }

        if has_started then last_started_index = i end
        if is_active then last_active_index = i end
    end

    menu.selected_index = last_active_index or
        last_started_index and subs[last_started_index + 1] and last_started_index + 1 or
        last_started_index or 1

    local json = utils.format_json(menu)
    if menu_open then
        mp.commandv('script-message-to', 'uosc', 'update-menu', json)
    else
        mp.commandv('script-message-to', 'uosc', 'open-menu', json)
    end
    menu_open = true
end

local function sub_text_update()
    if subtitles then show_subtitle_list(subtitles) end
end

-- ===== uosc 菜单回调处理 =====

mp.register_script_message('sub-loop-callback', function(json_event)
    local event = utils.parse_json(json_event)
    if not event then return end
    mp.msg.info('[LOOP_DEBUG] callback event: ' .. json_event:sub(1, 200))

    if event.type == 'activate' then
        if event.action then
            -- 点击了循环/取消循环按钮
            local action_str = tostring(event.action)
            mp.msg.info('[LOOP_DEBUG] action clicked: ' .. action_str)
            if action_str:match('^loop_(%d+)$') then
                local idx = tonumber(action_str:match('^loop_(%d+)$'))
                if idx and subtitles and subtitles[idx] then
                    -- 先取消其他循环标记
                    for k, _ in pairs(loop_state.sub_loop) do loop_state.sub_loop[k] = nil end
                    loop_state.sub_loop[idx] = true
                    begin_loop(idx, subtitles)  -- begin_loop 内部会 seek 到字幕起点
                    local text = subtitles[idx].line
                    osd(string.format('循环 x%d: %s', loop_state.repeat_count, trunc(text, 40)))
                end
            elseif action_str:match('^infinite_(%d+)$') then
                local idx = tonumber(action_str:match('^infinite_(%d+)$'))
                if idx and subtitles and subtitles[idx] then
                    for k, _ in pairs(loop_state.sub_loop) do loop_state.sub_loop[k] = nil end
                    loop_state.sub_loop[idx] = true
                    begin_loop(idx, subtitles, true)  -- is_infinite = true
                    local text = subtitles[idx].line
                    osd(string.format('无限循环 ∞: %s', trunc(text, 40)))
                end
            elseif action_str:match('^unloop_(%d+)$') then
                local idx = tonumber(action_str:match('^unloop_(%d+)$'))
                if idx then
                    loop_state.sub_loop[idx] = nil
                    if loop_state.active and loop_state.loop_sub_index == idx then
                        end_loop()
                    end
                    osd('已取消循环')
                end
            end
            sub_text_update()
        elseif event.value then
            -- 点击了字幕行 → seek 到该句
            local val = tostring(event.value)
            if val:match('^seek_(%d+)$') then
                local idx = tonumber(val:match('^seek_(%d+)$'))
                if idx and subtitles and subtitles[idx] then
                    mp.commandv('seek', tostring(subtitles[idx].start), 'absolute+exact')
                    sub_text_update()
                end
            end
        end
    end
end)

mp.register_script_message('uosc-menu-closed', function()
    mp.msg.info('[LOOP_DEBUG] uosc-menu-closed: 菜单关闭（保留 subtitles 供循环使用）')
    -- 不清空 subtitles，否则循环完成后无法跳下一句
    menu_open = false
    mp.unobserve_property(sub_text_update)
end)

-- ===== 核心：基于 sub-start 属性变化的精准循环检测 =====
--
-- 原理：sub-start 是 mpv 当前渲染字幕的起始时间。
-- 当字幕切换时，sub-start 会改变。
-- 这比 playback-time + buffer 方案更精确，因为：
--   1. 它直接反映字幕渲染管道的状态
--   2. 不依赖时间采样间隔
--   3. 不受 I帧 对齐影响
--   4. 天然处理字幕重叠/过渡

local function on_sub_start_change(_, new_start)
    if not loop_state.active then return end
    if not loop_state.target_start then return end

    -- seek 过渡期：忽略 sub-start 变化，防止误触发
    -- （seek 过程中 sub-start 可能短暂变为 nil 或中间值）
    if loop_state.seeking then
        -- 如果 sub-start 已经稳定回到目标值，提前解除保护
        if new_start and math.abs(new_start - loop_state.target_start) < 0.002 then
            loop_state.seeking = false
            mp.msg.info('[LOOP_DEBUG] seeking guard released early: sub-start settled at target')
        end
        return
    end

    -- 字幕已切换（sub-start 变了 ≠ 当前循环的字幕）
    -- new_start 为 nil 表示字幕已全部播放完毕
    if not new_start or math.abs(new_start - loop_state.target_start) > 0.002 then
        -- 循环次数 +1
        loop_state.loop_count = loop_state.loop_count + 1

        mp.msg.info(string.format('[LOOP_DEBUG] sub-start changed: %.2f → %s (count=%d/%d)',
            loop_state.target_start, tostring(new_start), loop_state.loop_count, loop_state.repeat_count))

        -- is_infinite 时永不自动停止（除非手动取消）
        if not loop_state.is_infinite and loop_state.loop_count >= loop_state.repeat_count then
            -- === 循环完成，跳下一句 ===
            local cur_idx = loop_state.loop_sub_index
            mp.msg.info(string.format('[LOOP_DEBUG] 循环完成 (%d/%d)，准备跳下一句',
                loop_state.loop_count, loop_state.repeat_count))
            end_loop()

            if loop_state.auto_advance and subtitles and cur_idx then
                local next_idx = cur_idx + 1
                if next_idx <= #subtitles then
                    mp.msg.info(string.format('[LOOP_DEBUG] seek 到下一句 idx=%d start=%.2f',
                        next_idx, subtitles[next_idx].start))
                    mp.commandv('seek', tostring(subtitles[next_idx].start), 'absolute+exact')
                    -- 自动开始下一句循环（如果该句也标记了循环）
                    if loop_state.sub_loop[next_idx] then
                        mp.msg.info('[LOOP_DEBUG] 下一句也标记了循环，自动开始')
                        begin_loop(next_idx, subtitles)
                    else
                        osd('循环完成 ✓')
                    end
                else
                    mp.msg.info('[LOOP_DEBUG] 已是最后一句，不跳转')
                    osd('已是最后一句')
                end
            end
            if menu_open then sub_text_update() end
        else
            -- === 还没到次数，seek 回起点继续循环 ===
            loop_state.seeking = true
            mp.commandv('seek', tostring(loop_state.target_start), 'absolute+exact')

            -- 延迟清除 seeking 保护
            local captured_target = loop_state.target_start  -- 捕获当前值防止 end_loop 后变 nil
            mp.add_timeout(0.4, function()
                if not loop_state.active then return end  -- 循环已被取消
                local current = mp.get_property_number('sub-start')
                if current and captured_target and math.abs(current - captured_target) < 0.01 then
                    loop_state.seeking = false
                else
                    -- 再等 0.3s 然后强制清除
                    mp.add_timeout(0.3, function()
                        if loop_state.active then loop_state.seeking = false end
                    end)
                end
            end)

            if subtitles and loop_state.loop_sub_index then
                local text = subtitles[loop_state.loop_sub_index].line
                if loop_state.is_infinite then
                    osd(string.format('[∞ x%d] %s', loop_state.loop_count + 1, trunc(text, 60)))
                else
                    osd(string.format('[%d/%d] %s',
                        math.min(loop_state.loop_count + 1, loop_state.repeat_count),
                        loop_state.repeat_count, trunc(text, 60)))
                end
            end
            if menu_open then sub_text_update() end
        end
    end
end

mp.observe_property('sub-start', 'number', on_sub_start_change)

-- ===== 按键绑定 =====

-- Ctrl+M / uosc 按钮 → 打开菜单（唯一入口）
local function open_sub_loop_ui()
    if menu_open then
        mp.commandv('script-message-to', 'uosc', 'close-menu', 'subtitle-lines-list')
        return
    end
    sub_strings = sub_strings_available.primary
    show_loading_indicator()
    subtitles = acquire_subtitles()
    mp.observe_property(sub_strings.text, 'string', sub_text_update)
    mp.add_timeout(0.1, function()
        if subtitles then show_subtitle_list(subtitles) end
    end)
end

mp.add_key_binding(nil, 'sub-loop-ui', open_sub_loop_ui)

-- Ctrl+Shift+L: 循环当前字幕（不打开菜单，直接开始循环）
mp.add_key_binding('ctrl+shift+l', 'sub-loop-toggle', function()
    if not subtitles then
        osd('请先打开字幕列表 (Ctrl+M)')
        return
    end
    local idx = find_current_sub_index(subtitles)
    if not idx then
        osd('当前无字幕')
        return
    end
    if loop_state.active and loop_state.loop_sub_index == idx then
        end_loop()
        loop_state.sub_loop[idx] = nil
        osd('循环: 关闭')
    else
        for k, _ in pairs(loop_state.sub_loop) do loop_state.sub_loop[k] = nil end
        loop_state.sub_loop[idx] = true
        begin_loop(idx, subtitles)
        local text = subtitles[idx].line
        if loop_state.is_infinite then
            osd(string.format('无限循环 ∞: %s', trunc(text, 60)))
        else
            osd(string.format('循环 x%d: %s', loop_state.repeat_count, trunc(text, 60)))
        end
    end
    if menu_open then sub_text_update() end
end)

-- Ctrl+Shift+1~9: 设置重复次数
for i = 1, 9 do
    mp.add_key_binding('ctrl+shift+' .. i, 'sub-loop-repeat-' .. i, function()
        loop_state.repeat_count = i
        osd(string.format('重复次数: x%d', i))
        if menu_open then sub_text_update() end
    end)
end

-- Ctrl+Shift+0: 直接启动当前字幕无限循环
mp.add_key_binding('ctrl+shift+0', 'sub-loop-infinite', function()
    if not subtitles then osd('请先打开字幕列表 (Ctrl+M)'); return end
    local idx = find_current_sub_index(subtitles)
    if not idx then osd('当前无字幕'); return end
    if loop_state.active and loop_state.loop_sub_index == idx then
        end_loop()
        loop_state.sub_loop[idx] = nil
        osd('循环: 关闭')
    else
        for k, _ in pairs(loop_state.sub_loop) do loop_state.sub_loop[k] = nil end
        loop_state.sub_loop[idx] = true
        begin_loop(idx, subtitles, true)  -- is_infinite = true
        local text = subtitles[idx].line
        osd(string.format('无限循环 ∞: %s', trunc(text, 60)))
    end
    if menu_open then sub_text_update() end
end)

-- Ctrl+Shift+A: 自动跳转开关
mp.add_key_binding('ctrl+shift+a', 'sub-loop-auto', function()
    loop_state.auto_advance = not loop_state.auto_advance
    osd(string.format('自动跳转: %s', loop_state.auto_advance and '开启' or '关闭'))
end)

-- Ctrl+Shift+→/←: 下一句/上一句
mp.add_key_binding('ctrl+shift+RIGHT', 'sub-loop-next', function()
    if not subtitles then return end
    local idx = find_current_sub_index(subtitles)
    if idx and idx < #subtitles then
        end_loop()
        mp.commandv('seek', tostring(subtitles[idx + 1].start), 'absolute+exact')
        if menu_open then sub_text_update() end
    end
end)

mp.add_key_binding('ctrl+shift+LEFT', 'sub-loop-prev', function()
    if not subtitles then return end
    local idx = find_current_sub_index(subtitles)
    if idx and idx > 1 then
        end_loop()
        mp.commandv('seek', tostring(subtitles[idx - 1].start), 'absolute+exact')
        if menu_open then sub_text_update() end
    end
end)

-- ===== uosc 工具栏按钮 =====

local function register_uosc_button()
    local data = utils.format_json({
        icon = 'menu_book',
        tooltip = '字幕循环学习',
        command = 'script-binding zzz_sub_loop/sub-loop-ui',
    })
    mp.commandv('script-message-to', 'uosc', 'set-button', 'sub_loop', data)
end

register_uosc_button()
mp.register_event('file-loaded', register_uosc_button)
mp.add_timeout(1, register_uosc_button)

-- ===== 事件处理 =====

mp.register_event('start-file', function()
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'subtitle-lines-list')
    subtitles = nil
    end_loop()
    loop_state.sub_loop = {}
end)

mp.register_event('end-file', function()
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'subtitle-lines-list')
end)

mp.msg.info('zzz-sub-loop 2.0 loaded (sub-start based precise loop detection)')
