-- @description ReaDLP - yt-dlp audio downloader for REAPER
-- @version 1.3.1
-- @author ReaDLP contributors
-- @about
--   # ReaDLP
--   ReaDLP is a ReaImGui tool for downloading organized sample-digging audio with yt-dlp and ffmpeg.
--   It supports single URLs, playlists, metadata-based filenames, saved field histories, logs, diagnostics, and optional insertion onto the selected REAPER track.
-- @changelog
--   Updated public package metadata and generic example paths.
--   Prepared the public ReaPack package layout.
--   Added a ReaPack metadata header.
--   Reworked the main UI into tabs for a smaller, cleaner window.
-- ReaDLP / yt-dlp audio downloader for REAPER
-- Add this file as a ReaScript action, then place it on a toolbar.
--
-- This action downloads audio from a URL using yt-dlp.exe. It does not use
-- Python. Install yt-dlp.exe and ffmpeg.exe on the DAW machine first.

local SCRIPT_NAME = "ReaDLP"
local EXT_SECTION = "READLP_PUB"

-- Settings users are expected to edit.
local SETTINGS = {
  -- Keep this false if you do not want the script to inspect the clipboard.
  -- When true, the URL prompt is pre-filled from the Windows clipboard if it
  -- looks like a web URL.
  READ_CLIPBOARD_BY_DEFAULT = false,

  -- Optional absolute path. Leave blank to auto-detect yt-dlp.exe from:
  -- 1. this script's folder, 2. REAPER resource path, 3. PATH.
  YT_DLP_EXE = "",

  -- Optional path to ffmpeg.exe or a folder containing ffmpeg.exe/ffprobe.exe.
  -- Leave blank to auto-detect ffmpeg next to this script, next to yt-dlp.exe,
  -- or from PATH.
  FFMPEG_LOCATION = "",

  -- Optional folder for log files. Leave blank for:
  -- REAPER resource path\Logs\ReaDLP
  LOG_FOLDER = "",

  -- Manual updates are available from the menu. Keep automatic updates off by
  -- default so the action stays fast and predictable during a session.
  DEFAULT_AUTO_UPDATE_YT_DLP = false,

  -- When true, successful downloads are inserted on the first selected track at
  -- the current edit cursor. This can also be toggled from the action menu.
  DEFAULT_INSERT_AFTER_DOWNLOAD = false,

  -- Leave blank to update the current yt-dlp release channel with -U.
  -- Use "nightly" to run: yt-dlp --update-to nightly
  YT_DLP_UPDATE_TARGET = "",

  -- "best" preserves the best available audio format. Common forced choices:
  -- "opus", "m4a", "mp3", "aac", "flac", "vorbis". Avoid "wav" unless you
  -- specifically want huge uncompressed files.
  DEFAULT_AUDIO_FORMAT = "best",

  -- Set to true if you want the first menu state to target the saved REAPER
  -- project folder. The action still blocks this when the project is unsaved.
  DEFAULT_USE_PROJECT_FOLDER = false,

  -- Optional named destinations for the menu. Edit these on the DAW machine.
  -- Example:
  -- { name = "Main sample library", path = "D:\\Samples\\Main" },
  QUICK_FOLDERS = {
    -- { name = "Main sample library", path = "D:\\Samples\\Main" },
    -- { name = "Vinyl rips", path = "D:\\Samples\\Vinyl" },
    -- { name = "YouTube finds", path = "D:\\Samples\\YouTube" },
  },

  -- Downloads run in the background by default. Logs remain available in the
  -- interface, but no command prompt is opened or paused.
  SHOW_COMMAND_WINDOW = false,
}

local FORMAT_CHOICES = {
  { label = "Best native", value = "best" },
  { label = "Opus", value = "opus" },
  { label = "M4A", value = "m4a" },
  { label = "MP3", value = "mp3" },
  { label = "AAC", value = "aac" },
  { label = "FLAC", value = "flac" },
  { label = "Vorbis", value = "vorbis" },
}

local KEY_PAIRS = {
  { major = "C", minor = "Am" },
  { major = "C#", minor = "A#m" },
  { major = "D", minor = "Bm" },
  { major = "D#", minor = "Cm" },
  { major = "E", minor = "C#m" },
  { major = "F", minor = "Dm" },
  { major = "F#", minor = "D#m" },
  { major = "G", minor = "Em" },
  { major = "G#", minor = "Fm" },
  { major = "A", minor = "F#m" },
  { major = "A#", minor = "Gm" },
  { major = "B", minor = "G#m" },
}

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function file_exists(path)
  if path == "" then return false end
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function exec_exit_code(output)
  local code = tostring(output or ""):match("^%s*(-?%d+)")
  return code and tonumber(code) or nil
end

local function directory_exists(path)
  if path == "" then return false end
  path = trim(path):gsub("/", "\\"):gsub("\\+$", "")
  path = path:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")

  local ps_path = "'" .. path:gsub("'", "''") .. "'"
  local ps = "if (Test-Path -LiteralPath " .. ps_path .. " -PathType Container) { exit 0 } else { exit 1 }"
  local ps_command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "' .. ps:gsub('"', '\\"') .. '"'
  local ps_ran, ps_output = pcall(reaper.ExecProcess, ps_command, 5000)
  if ps_ran and exec_exit_code(ps_output) == 0 then return true end

  local ok, _, code = os.rename(path, path)
  if ok then return true end
  if code == 13 then return true end

  local check_path = path .. "\\NUL"
  local quoted = '"' .. check_path:gsub('"', "'") .. '"'
  local command = 'cmd.exe /C if exist ' .. quoted .. ' (exit /b 0) else (exit /b 1)'
  local ran, output = pcall(reaper.ExecProcess, command, 2500)
  if not ran then return false end
  return exec_exit_code(output) == 0
end

local function script_dir()
  local source = debug.getinfo(1, "S").source
  local path = source:sub(1, 1) == "@" and source:sub(2) or source
  return path:match("^(.*)[/\\]") or "."
end

local function parent_dir(path)
  return tostring(path or ""):match("^(.*)[/\\][^/\\]+$") or ""
end

local function normalize_path(path)
  path = trim(path):gsub("/", "\\")
  path = path:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
  return path:gsub("\\+$", "")
end

local function batch_arg(value)
  value = tostring(value or ""):gsub('"', "'")
  value = value:gsub("%%", "%%%%")
  return '"' .. value .. '"'
end

local function win_arg(value)
  value = tostring(value or ""):gsub('"', "'")
  return '"' .. value .. '"'
end

local function batch_echo_text(value)
  value = tostring(value or ""):gsub("%%", "%%%%")
  value = value:gsub("%^", "^^")
  value = value:gsub("&", "^&")
  value = value:gsub("|", "^|")
  value = value:gsub("<", "^<")
  value = value:gsub(">", "^>")
  return value
end

local function ps_single_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function message(text)
  reaper.ShowMessageBox(text, SCRIPT_NAME, 0)
end

local settings_cache = nil

local function settings_folder()
  return reaper.GetResourcePath() .. "\\Data\\ReaDLP"
end

local function settings_file_path()
  return settings_folder() .. "\\settings.ini"
end

local function encode_setting(value)
  value = tostring(value or "")
  value = value:gsub("%%", "%%25")
  value = value:gsub("\r", "%%0D")
  value = value:gsub("\n", "%%0A")
  return value
end

local function decode_setting(value)
  value = tostring(value or "")
  value = value:gsub("%%0D", "\r")
  value = value:gsub("%%0A", "\n")
  value = value:gsub("%%25", "%%")
  return value
end

local function ensure_settings_loaded()
  if settings_cache then return end
  settings_cache = {}

  local f = io.open(settings_file_path(), "rb")
  if not f then return end

  for line in f:lines() do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then settings_cache[key] = decode_setting(value) end
  end

  f:close()
end

local function save_settings_file()
  ensure_settings_loaded()

  local folder = settings_folder()
  if not directory_exists(folder) then
    reaper.RecursiveCreateDirectory(folder, 0)
  end

  local f = io.open(settings_file_path(), "wb")
  if not f then return false end

  local keys = {}
  for key in pairs(settings_cache) do keys[#keys + 1] = key end
  table.sort(keys)

  for _, key in ipairs(keys) do
    f:write(key, "=", encode_setting(settings_cache[key]), "\n")
  end

  f:close()
  return true
end

local function get_state(key, fallback)
  ensure_settings_loaded()
  if settings_cache[key] ~= nil then return settings_cache[key] end

  local value = reaper.GetExtState(EXT_SECTION, key)
  if value == "" then return fallback end

  settings_cache[key] = value
  save_settings_file()
  return value
end

local function set_state(key, value)
  value = tostring(value or "")
  ensure_settings_loaded()
  settings_cache[key] = value
  save_settings_file()

  if not value:find("[\r\n]") then
    reaper.SetExtState(EXT_SECTION, key, value, true)
  end
end

local function get_bool_state(key, fallback)
  local default = fallback and "1" or "0"
  return get_state(key, default) == "1"
end

local function set_bool_state(key, value)
  set_state(key, value and "1" or "0")
end

local function split_list(value)
  local items = {}
  for item in tostring(value or ""):gmatch("[^\n]+") do
    item = trim(item)
    if item ~= "" then items[#items + 1] = item end
  end
  return items
end

local function join_list(items)
  return table.concat(items or {}, "\n")
end

local function list_contains(items, value)
  local lowered = trim(value):lower()
  if lowered == "" then return true end
  for _, item in ipairs(items or {}) do
    if item:lower() == lowered then return true end
  end
  return false
end

local function add_to_saved_list(state_key, value)
  value = trim(value)
  if value == "" then return end
  value = value:gsub("[\r\n]+", " ")

  local items = split_list(get_state(state_key, ""))
  if not list_contains(items, value) then
    table.insert(items, 1, value)
    while #items > 80 do table.remove(items) end
    set_state(state_key, join_list(items))
  end
end

local function sanitize_filename_part(value)
  value = trim(value)
  value = value:gsub('[<>:"/\\|?*]', "-")
  value = value:gsub("[%s_]+", "-")
  value = value:gsub("%-+", "-")
  value = value:gsub("^%-+", ""):gsub("%-+$", "")
  value = value:gsub("^%s+", ""):gsub("%s+$", "")
  value = value:gsub("%.+$", "")
  return value
end

local function build_output_template(style, region, channel, artist, year, key, tempo)
  local before = {}
  local after = {}
  local style_part = sanitize_filename_part(style)
  local region_part = sanitize_filename_part(region)
  local channel_part = sanitize_filename_part(channel)
  local artist_part = sanitize_filename_part(artist)
  local year_part = sanitize_filename_part(year)
  local key_part = sanitize_filename_part(key)
  local tempo_part = sanitize_filename_part(tempo)

  if style_part ~= "" then before[#before + 1] = style_part end
  if region_part ~= "" then before[#before + 1] = region_part end
  if channel_part ~= "" then before[#before + 1] = channel_part end
  if artist_part ~= "" then before[#before + 1] = artist_part end
  if year_part ~= "" then after[#after + 1] = year_part end
  if key_part ~= "" then after[#after + 1] = key_part end
  if tempo_part ~= "" then after[#after + 1] = tempo_part end

  local parts = {}
  for _, item in ipairs(before) do parts[#parts + 1] = item end
  parts[#parts + 1] = "%(title).180s"
  for _, item in ipairs(after) do parts[#parts + 1] = item end

  return table.concat(parts, "_") .. ".%(ext)s"
end

local function is_playlist_url(url)
  url = tostring(url or "")
  return url:match("[?&]list=[^&]+") ~= nil or url:match("youtube%.com/playlist%?") ~= nil
end

local function playlist_output_template()
  return "%(playlist_title).180s/%(playlist_index)03d - %(title).180s.%(ext)s"
end

local function get_project_folder()
  local _, project_file = reaper.EnumProjects(-1, "")
  project_file = project_file or ""
  if project_file == "" then return "" end
  return project_file:match("^(.*)[/\\]") or ""
end

local function get_clipboard_url()
  if not SETTINGS.READ_CLIPBOARD_BY_DEFAULT then return "" end

  local command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Clipboard -Raw"'
  local ok, output = pcall(reaper.ExecProcess, command, 1500)
  if not ok then return "" end

  output = trim((output or ""):gsub("\r", "\n"))
  local url = output:match("(https?://%S+)")
  if url then return trim(url) end
  return ""
end

local function first_existing_file_from_output(output)
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    local path = trim(line)
    if file_exists(path) then return path end
  end
  return ""
end

local function find_on_path(exe_name)
  local ok, output = pcall(reaper.ExecProcess, 'cmd.exe /C where ' .. exe_name, 2500)
  if not ok then return "" end

  return first_existing_file_from_output(output)
end

local function find_winget_exe(exe_name, package_filter)
  local ps = "$root = Join-Path $env:LOCALAPPDATA 'Microsoft\\WinGet\\Packages'; " ..
    "if (Test-Path -LiteralPath $root) { " ..
    "Get-ChildItem -LiteralPath $root -Directory -Filter " .. ps_single_quote(package_filter) .. " -ErrorAction SilentlyContinue | " ..
    "ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter " .. ps_single_quote(exe_name) .. " -File -ErrorAction SilentlyContinue } | " ..
    "Select-Object -First 1 -ExpandProperty FullName }"

  local command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " .. win_arg(ps)
  local ok, output = pcall(reaper.ExecProcess, command, 6000)
  if not ok then return "" end

  return first_existing_file_from_output(output)
end

local function find_yt_dlp()
  local candidates = {
    normalize_path(SETTINGS.YT_DLP_EXE),
    script_dir() .. "\\yt-dlp.exe",
    reaper.GetResourcePath() .. "\\Scripts\\ReaDLP\\yt-dlp.exe",
    reaper.GetResourcePath() .. "\\Scripts\\REA-DLP\\yt-dlp.exe",
  }

  for _, path in ipairs(candidates) do
    if file_exists(path) then return path end
  end

  local on_path = find_on_path("yt-dlp.exe")
  if on_path ~= "" then return on_path end

  return find_winget_exe("yt-dlp.exe", "yt-dlp.yt-dlp_*")
end

local function folder_has_ffmpeg(folder)
  folder = normalize_path(folder)
  return folder ~= "" and file_exists(folder .. "\\ffmpeg.exe")
end

local function find_ffmpeg_location(yt_dlp)
  local configured = normalize_path(SETTINGS.FFMPEG_LOCATION)
  if configured ~= "" then
    if directory_exists(configured) then return configured end
    if file_exists(configured) then return configured end
  end

  local yt_dlp_dir = parent_dir(yt_dlp)
  local candidates = {
    script_dir(),
    script_dir() .. "\\ffmpeg\\bin",
    yt_dlp_dir,
    yt_dlp_dir .. "\\ffmpeg\\bin",
    reaper.GetResourcePath() .. "\\Scripts\\ReaDLP",
    reaper.GetResourcePath() .. "\\Scripts\\ReaDLP\\ffmpeg\\bin",
    reaper.GetResourcePath() .. "\\Scripts\\REA-DLP",
    reaper.GetResourcePath() .. "\\Scripts\\REA-DLP\\ffmpeg\\bin",
  }

  for _, folder in ipairs(candidates) do
    if folder_has_ffmpeg(folder) then return normalize_path(folder) end
  end

  local ffmpeg_on_path = find_on_path("ffmpeg.exe")
  if ffmpeg_on_path ~= "" then return parent_dir(ffmpeg_on_path) end

  local ffmpeg_winget = find_winget_exe("ffmpeg.exe", "yt-dlp.FFmpeg_*")
  if ffmpeg_winget ~= "" then return parent_dir(ffmpeg_winget) end

  ffmpeg_winget = find_winget_exe("ffmpeg.exe", "Gyan.FFmpeg_*")
  if ffmpeg_winget ~= "" then return parent_dir(ffmpeg_winget) end

  return ""
end

local function format_label(format_value)
  for _, item in ipairs(FORMAT_CHOICES) do
    if item.value == format_value then return item.label end
  end
  return format_value
end

local function ask_for_folder(current_folder)
  local default = current_folder ~= "" and current_folder or reaper.GetResourcePath()
  local ok, value = reaper.GetUserInputs(SCRIPT_NAME, 1, "Save folder path:,extrawidth=240", default)
  if not ok then return "" end
  return normalize_path(value)
end

local function ask_for_url()
  local clipboard_url = get_clipboard_url()
  local default_url = clipboard_url ~= "" and clipboard_url or get_state("last_url", "")
  local ok, value = reaper.GetUserInputs(SCRIPT_NAME, 1, "Video/page URL:,extrawidth=320", default_url)
  if not ok then return "" end

  local url = trim(value)
  if url ~= "" then set_state("last_url", url) end
  return url
end

local function get_destination(use_project_folder, saved_folder)
  if use_project_folder then
    local project_folder = get_project_folder()
    if project_folder ~= "" then return project_folder end

    local result = reaper.ShowMessageBox(
      "This REAPER project has not been saved yet, so it has no project folder.\n\nChoose a normal save folder instead?",
      SCRIPT_NAME,
      4
    )
    if result ~= 6 then return "" end
  end

  local folder = normalize_path(saved_folder)
  if folder == "" then
    folder = ask_for_folder(folder)
  end

  if folder == "" then return "" end
  return folder
end

local function ensure_folder(folder)
  if directory_exists(folder) then return true end
  local ok = reaper.RecursiveCreateDirectory(folder, 0)
  if ok == 1 or directory_exists(folder) then return true end

  local ps = "New-Item -ItemType Directory -Force -LiteralPath " .. ps_single_quote(folder) .. " | Out-Null"
  local command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " .. win_arg(ps)
  pcall(reaper.ExecProcess, command, 5000)
  return directory_exists(folder)
end

local function get_log_folder()
  local configured = normalize_path(SETTINGS.LOG_FOLDER)
  if configured ~= "" then return configured end
  return reaper.GetResourcePath() .. "\\Logs\\" .. SCRIPT_NAME
end

local function timestamp()
  return os.date("%Y%m%d_%H%M%S")
end

local function run_id()
  local precise = tostring(reaper.time_precise and reaper.time_precise() or os.time())
  return timestamp() .. "_" .. precise:gsub("%D", "")
end

local function update_command_parts(yt_dlp)
  local target = trim(SETTINGS.YT_DLP_UPDATE_TARGET)
  if target ~= "" then
    return { batch_arg(yt_dlp), "--update-to", batch_arg(target) }
  end
  return { batch_arg(yt_dlp), "-U" }
end

local function read_text_file(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local text = f:read("*a") or ""
  f:close()
  return text
end

local function last_nonempty_line(text)
  local last = ""
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local value = trim(line)
    if value ~= "" then last = value end
  end
  return last
end

local function write_download_batch_file(url, destination, audio_format, yt_dlp, ffmpeg_location, log_path, auto_update, final_path_file, status_file, output_template, show_window, playlist_mode)
  local temp_dir = os.getenv("TEMP") or destination
  local batch_path = temp_dir .. "\\rea_dlp_audio_" .. run_id() .. ".cmd"
  output_template = output_template or "%(title).180s.%(ext)s"
  local download_command = {
    batch_arg(yt_dlp),
    "--windows-filenames",
    "--newline",
    "--console-title",
    "-f", batch_arg("bestaudio/best"),
    "-x",
    "--audio-format", batch_arg(audio_format),
    "--audio-quality", batch_arg("0"),
    "--paths", batch_arg("home:" .. destination),
    "-o", batch_arg(output_template),
  }

  table.insert(download_command, 2, playlist_mode and "--yes-playlist" or "--no-playlist")

  if trim(ffmpeg_location) ~= "" then
    table.insert(download_command, "--ffmpeg-location")
    table.insert(download_command, batch_arg(normalize_path(ffmpeg_location)))
  end

  table.insert(download_command, batch_arg(url))

  local lines = {
    "@echo off",
    "title " .. SCRIPT_NAME,
    "cd /d " .. batch_arg(destination),
    "call :run > " .. batch_arg(log_path) .. " 2>&1",
    "set EXITCODE=%ERRORLEVEL%",
    "> " .. batch_arg(status_file) .. " echo(%EXITCODE%",
    "exit /b %EXITCODE%",
    "",
    ":run",
    "echo Started: %DATE% %TIME%",
    "echo yt-dlp: " .. batch_echo_text(yt_dlp),
    "echo ffmpeg location: " .. batch_echo_text(ffmpeg_location ~= "" and ffmpeg_location or "PATH/default"),
    "echo URL: " .. batch_echo_text(url),
    "echo Output: " .. batch_echo_text(destination),
    "echo Format: " .. batch_echo_text(audio_format),
    "echo Playlist mode: " .. (playlist_mode and "true" or "false"),
    "echo Output template: " .. batch_echo_text(output_template),
    "echo Log: " .. batch_echo_text(log_path),
    "echo Final path source: log destination lines, with newest-audio fallback for Unicode paths",
    "echo.",
    batch_arg(yt_dlp) .. " --version",
    "echo.",
  }

  if auto_update then
    table.insert(lines, "echo Updating yt-dlp before download...")
    table.insert(lines, table.concat(update_command_parts(yt_dlp), " "))
    table.insert(lines, "echo.")
  end

  table.insert(lines, "echo Download command:")
  table.insert(lines, "echo " .. batch_echo_text(table.concat(download_command, " ")))
  table.insert(lines, "echo.")
  table.insert(lines, table.concat(download_command, " "))
  table.insert(lines, "set RUN_EXIT=%ERRORLEVEL%")
  table.insert(lines, "echo.")
  table.insert(lines, "echo Finished: %DATE% %TIME%")
  table.insert(lines, "exit /b %RUN_EXIT%")

  if show_window then
    table.insert(lines, 7, "type " .. batch_arg(log_path))
    table.insert(lines, 8, "echo.")
    table.insert(lines, 9, "echo Log file: " .. batch_echo_text(log_path))
    table.insert(lines, 10, "echo.")
    table.insert(lines, 11, "if %EXITCODE% EQU 0 (")
    table.insert(lines, 12, "  echo Done.")
    table.insert(lines, 13, ") else (")
    table.insert(lines, 14, "  echo Failed with exit code %EXITCODE%.")
    table.insert(lines, 15, ")")
    table.insert(lines, 16, "echo.")
    table.insert(lines, 17, "pause")
  end

  local f = io.open(batch_path, "wb")
  if not f then return "" end
  f:write(table.concat(lines, "\r\n"))
  f:write("\r\n")
  f:close()
  return batch_path
end

local function write_update_batch_file(yt_dlp, log_path, show_window)
  local temp_dir = os.getenv("TEMP") or reaper.GetResourcePath()
  local batch_path = temp_dir .. "\\rea_dlp_update_" .. run_id() .. ".cmd"
  local update_command = update_command_parts(yt_dlp)
  local lines = {
    "@echo off",
    "title " .. SCRIPT_NAME .. " - Update yt-dlp",
    "call :run > " .. batch_arg(log_path) .. " 2>&1",
    "set EXITCODE=%ERRORLEVEL%",
    "exit /b %EXITCODE%",
    "",
    ":run",
    "echo Started: %DATE% %TIME%",
    "echo yt-dlp: " .. batch_echo_text(yt_dlp),
    "echo Update command:",
    "echo " .. batch_echo_text(table.concat(update_command, " ")),
    "echo.",
    table.concat(update_command, " "),
    "set RUN_EXIT=%ERRORLEVEL%",
    "echo.",
    batch_arg(yt_dlp) .. " --version",
    "echo Finished: %DATE% %TIME%",
    "exit /b %RUN_EXIT%",
  }

  if show_window then
    table.insert(lines, 5, "type " .. batch_arg(log_path))
    table.insert(lines, 6, "echo.")
    table.insert(lines, 7, "echo Log file: " .. batch_echo_text(log_path))
    table.insert(lines, 8, "echo.")
    table.insert(lines, 9, "if %EXITCODE% EQU 0 (")
    table.insert(lines, 10, "  echo yt-dlp update finished.")
    table.insert(lines, 11, ") else (")
    table.insert(lines, 12, "  echo yt-dlp update failed with exit code %EXITCODE%.")
    table.insert(lines, 13, ")")
    table.insert(lines, 14, "echo.")
    table.insert(lines, 15, "pause")
  end

  local f = io.open(batch_path, "wb")
  if not f then return "" end
  f:write(table.concat(lines, "\r\n"))
  f:write("\r\n")
  f:close()
  return batch_path
end

local function make_log_path(kind)
  local log_folder = get_log_folder()
  if not ensure_folder(log_folder) then
    log_folder = os.getenv("TEMP") or reaper.GetResourcePath()
  end
  return log_folder .. "\\rea_dlp_" .. kind .. "_" .. timestamp() .. ".log"
end

local function launch_batch(batch_path, show_window)
  if show_window then
    local launch = 'cmd.exe /C start "" ' .. batch_arg(batch_path)
    pcall(reaper.ExecProcess, launch, 1000)
    return
  end

  local ps = "Start-Process -WindowStyle Hidden -FilePath 'cmd.exe' -ArgumentList @('/C', " .. ps_single_quote(batch_path) .. ")"
  local launch = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " .. win_arg(ps)
  pcall(reaper.ExecProcess, launch, 1000)
end

local function insert_file_on_track(path, target_track, insert_position, fixed_lane)
  if not target_track or not reaper.ValidatePtr2(0, target_track, "MediaTrack*") then
    message("Download finished, but the original selected track is no longer available.\n\nFile:\n" .. path)
    return
  end

  local selected_tracks = {}
  local track_count = reaper.CountTracks(0)
  local before_count = reaper.CountTrackMediaItems(target_track)

  for index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, index)
    selected_tracks[#selected_tracks + 1] = {
      track = track,
      selected = reaper.IsTrackSelected(track),
    }
    reaper.SetTrackSelected(track, false)
  end

  reaper.SetTrackSelected(target_track, true)
  local previous_cursor = reaper.GetCursorPosition()
  reaper.SetEditCurPos(insert_position, false, false)

  if fixed_lane then
    reaper.SetMediaTrackInfo_Value(target_track, "I_FREEMODE", 2)
    local current_lanes = math.floor(reaper.GetMediaTrackInfo_Value(target_track, "I_NUMFIXEDLANES") or 0)
    if current_lanes <= fixed_lane then
      reaper.SetMediaTrackInfo_Value(target_track, "I_NUMFIXEDLANES", fixed_lane + 1)
    end
    reaper.SetMediaTrackInfo_Value(target_track, "C_ALLLANESPLAY", 1)
    reaper.UpdateTimeline()
  end

  reaper.InsertMedia(path, 0)
  reaper.SetEditCurPos(previous_cursor, false, false)

  if fixed_lane then
    local after_count = reaper.CountTrackMediaItems(target_track)
    for index = before_count, after_count - 1 do
      local item = reaper.GetTrackMediaItem(target_track, index)
      if item then
        reaper.SetMediaItemInfo_Value(item, "I_FIXEDLANE", fixed_lane)
        reaper.SetMediaItemInfo_Value(item, "C_LANEPLAYS", 2)
      end
    end
    reaper.UpdateItemLanes(0)
  end

  for _, item in ipairs(selected_tracks) do
    reaper.SetTrackSelected(item.track, item.selected)
  end

  reaper.UpdateArrange()
end

local function final_path_from_log(log_path)
  local final_path = ""
  local log_text = read_text_file(log_path)
  for line in tostring(log_text or ""):gmatch("[^\r\n]+") do
    local extracted_path = line:match("^%[ExtractAudio%] Destination:%s*(.+)$")
    local downloaded_path = line:match("^%[download%] Destination:%s*(.+)$")
    if extracted_path and file_exists(trim(extracted_path)) then
      final_path = trim(extracted_path)
    elseif final_path == "" and downloaded_path and file_exists(trim(downloaded_path)) then
      final_path = trim(downloaded_path)
    end
  end
  return final_path
end

local function newest_audio_file_in_folder(folder)
  folder = normalize_path(folder)
  if folder == "" then return "" end

  local temp_dir = os.getenv("TEMP") or reaper.GetResourcePath()
  local output_path = temp_dir .. "\\rea_dlp_newest_audio_" .. run_id() .. ".txt"
  local ps =
    "$exts = @('.opus','.m4a','.mp3','.aac','.flac','.ogg','.oga','.vorbis','.wav','.aif','.aiff','.wma'); " ..
    "$latest = Get-ChildItem -LiteralPath " .. ps_single_quote(folder) .. " -File -ErrorAction SilentlyContinue | " ..
    "Where-Object { $exts -contains $_.Extension.ToLowerInvariant() } | " ..
    "Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1; " ..
    "if ($latest) { " ..
    "$enc = New-Object System.Text.UTF8Encoding $false; " ..
    "[System.IO.File]::WriteAllText(" .. ps_single_quote(output_path) .. ", $latest.FullName, $enc) " ..
    "}"

  local command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " .. win_arg(ps)
  pcall(reaper.ExecProcess, command, 5000)
  return trim(read_text_file(output_path))
end

local function watch_download_for_insert(final_path_file, status_file, log_path, destination, target_track, insert_position, fixed_lane)
  if not file_exists(status_file) then
    reaper.defer(function()
      watch_download_for_insert(final_path_file, status_file, log_path, destination, target_track, insert_position, fixed_lane)
    end)
    return
  end

  local exit_code = trim(read_text_file(status_file))
  if exit_code == "" then
    reaper.defer(function()
      watch_download_for_insert(final_path_file, status_file, log_path, destination, target_track, insert_position, fixed_lane)
    end)
    return
  end

  if exit_code ~= "0" then
    message(
      "Download finished with an error, so nothing was inserted.\n\n" ..
      "Exit code: " .. (exit_code ~= "" and exit_code or "unknown") .. "\n\n" ..
      "Use Logs > Copy latest log to clipboard for details."
    )
    return
  end

  local final_path = last_nonempty_line(read_text_file(final_path_file))
  local allow_unverified_insert = false
  if final_path == "" or not file_exists(final_path) then
    final_path = final_path_from_log(log_path)
  end

  if final_path == "" or not file_exists(final_path) then
    final_path = newest_audio_file_in_folder(destination)
    allow_unverified_insert = final_path ~= ""
  end

  if final_path == "" or (not allow_unverified_insert and not file_exists(final_path)) then
    message(
      "Download finished, but the final audio path could not be found.\n\n" ..
      "Log file:\n" .. log_path
    )
    return
  end

  insert_file_on_track(final_path, target_track, insert_position, fixed_lane)
end

local function copy_latest_log_to_clipboard()
  local log_path = get_state("latest_log", "")
  if log_path == "" or not file_exists(log_path) then
    message("No log file has been written yet.")
    return
  end

  local command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " ..
    win_arg("Get-Content -Raw -LiteralPath " .. ps_single_quote(log_path) .. " | Set-Clipboard")
  local ok = pcall(reaper.ExecProcess, command, 5000)
  if ok then
    message("Copied latest log to clipboard:\n\n" .. log_path)
  else
    message("Could not copy the latest log to clipboard:\n\n" .. log_path)
  end
end

local function insert_latest_download_on_selected_track()
  local log_path = get_state("latest_log", "")
  if log_path == "" or not file_exists(log_path) then
    message("No latest log file was found.")
    return
  end

  local final_path = final_path_from_log(log_path)
  local allow_unverified_insert = false
  if final_path == "" or not file_exists(final_path) then
    local use_project_folder = get_bool_state("use_project_folder", SETTINGS.DEFAULT_USE_PROJECT_FOLDER)
    local destination = use_project_folder and get_project_folder() or normalize_path(get_state("save_folder", ""))
    final_path = newest_audio_file_in_folder(destination)
    allow_unverified_insert = final_path ~= ""
  end

  if final_path == "" or (not allow_unverified_insert and not file_exists(final_path)) then
    message("Could not find a downloaded audio file in the latest log:\n\n" .. log_path)
    return
  end

  local target_track = reaper.GetSelectedTrack(0, 0)
  if not target_track then
    message("Select a track first, then run this action again.\n\nFile:\n" .. final_path)
    return
  end

  insert_file_on_track(final_path, target_track, reaper.GetCursorPosition(), nil)
end

local function open_logs_folder()
  local log_folder = get_log_folder()
  ensure_folder(log_folder)
  pcall(reaper.ExecProcess, 'cmd.exe /C start "" ' .. batch_arg(log_folder), 1000)
end

local function command_output_without_exit_line(output)
  local lines = {}
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    local value = trim(line)
    if not (#lines == 0 and value:match("^%-?%d+$")) then
      lines[#lines + 1] = value
    end
  end
  if #lines == 0 then return "<no output>" end
  return table.concat(lines, "\r\n")
end

local function cmd_output_clean(command, timeout)
  local ok, output = pcall(reaper.ExecProcess, command, timeout or 2500)
  if not ok then return "<command failed>" end
  output = trim(output or "")
  if output == "" then return "<no output>" end
  return command_output_without_exit_line(output)
end

local function copy_tool_diagnostics_to_clipboard()
  local yt_dlp = find_yt_dlp()
  local ffmpeg_location = yt_dlp ~= "" and find_ffmpeg_location(yt_dlp) or find_ffmpeg_location("")
  local lines = {
    "ReaDLP tool diagnostics",
    "Script folder: " .. script_dir(),
    "REAPER resource path: " .. reaper.GetResourcePath(),
    "Settings file: " .. settings_file_path(),
    "Settings file exists: " .. (file_exists(settings_file_path()) and "true" or "false"),
    "Saved locations count: " .. tostring(#split_list(get_state("saved_locations", ""))),
    "Detected yt-dlp: " .. (yt_dlp ~= "" and yt_dlp or "<not found>"),
    "Detected ffmpeg location: " .. (ffmpeg_location ~= "" and ffmpeg_location or "<not found>"),
    "",
    "cmd /C where yt-dlp.exe:",
    cmd_output_clean("cmd.exe /C where yt-dlp.exe", 2500),
    "",
    "cmd /C where ffmpeg.exe:",
    cmd_output_clean("cmd.exe /C where ffmpeg.exe", 2500),
  }

  local text = table.concat(lines, "\r\n")
  local command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " ..
    win_arg("$input | Set-Clipboard")

  local temp_dir = os.getenv("TEMP") or reaper.GetResourcePath()
  local diag_path = temp_dir .. "\\rea_dlp_tool_diagnostics_" .. run_id() .. ".txt"
  local f = io.open(diag_path, "wb")
  if f then
    f:write(text)
    f:close()
    command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " ..
      win_arg("Get-Content -Raw -LiteralPath " .. ps_single_quote(diag_path) .. " | Set-Clipboard")
    pcall(reaper.ExecProcess, command, 5000)
    message("Copied ReaDLP tool diagnostics to clipboard.")
  else
    message(text)
  end
end

local function copy_save_folder_diagnostics_to_clipboard()
  local use_project_folder = get_bool_state("use_project_folder", SETTINGS.DEFAULT_USE_PROJECT_FOLDER)
  local folder = use_project_folder and get_project_folder() or normalize_path(get_state("save_folder", ""))
  local ps_folder = "'" .. folder:gsub("'", "''") .. "'"
  local ps_command_text = "if (Test-Path -LiteralPath " .. ps_folder .. " -PathType Container) { 'exists' } else { 'missing' }"
  local cmd_check_path = folder .. "\\."
  local cmd_check = 'cmd.exe /C if exist ' .. win_arg(cmd_check_path) .. ' (echo exists) else (echo missing)'

  local lines = {
    "ReaDLP save folder diagnostics",
    "Use project folder: " .. (use_project_folder and "true" or "false"),
    "Saved/project folder: " .. (folder ~= "" and folder or "<blank>"),
    "directory_exists result: " .. (directory_exists(folder) and "true" or "false"),
    "",
    "PowerShell Test-Path result:",
    cmd_output_clean("powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " .. win_arg(ps_command_text), 5000),
    "",
    "cmd if exist result:",
    cmd_output_clean(cmd_check, 2500),
  }

  local text = table.concat(lines, "\r\n")
  local temp_dir = os.getenv("TEMP") or reaper.GetResourcePath()
  local diag_path = temp_dir .. "\\rea_dlp_save_folder_diagnostics_" .. run_id() .. ".txt"
  local f = io.open(diag_path, "wb")
  if f then
    f:write(text)
    f:close()
    local command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " ..
      win_arg("Get-Content -Raw -LiteralPath " .. ps_single_quote(diag_path) .. " | Set-Clipboard")
    pcall(reaper.ExecProcess, command, 5000)
    message("Copied ReaDLP save folder diagnostics to clipboard.")
  else
    message(text)
  end
end

local function run_update()
  local yt_dlp = find_yt_dlp()
  if yt_dlp == "" then
    message(
      "Could not find yt-dlp.exe.\n\n" ..
      "Put yt-dlp.exe in the same folder as this script, or set SETTINGS.YT_DLP_EXE at the top of the script."
    )
    return
  end

  local log_path = make_log_path("update")
  set_state("latest_log", log_path)

  local batch_path = write_update_batch_file(yt_dlp, log_path, SETTINGS.SHOW_COMMAND_WINDOW)
  if batch_path == "" then
    message("Could not write the temporary update command.")
    return
  end

  launch_batch(batch_path, SETTINGS.SHOW_COMMAND_WINDOW)
end

local function run_download()
  local yt_dlp = find_yt_dlp()
  if yt_dlp == "" then
    message(
      "Could not find yt-dlp.exe.\n\n" ..
      "Put yt-dlp.exe in the same folder as this script, or set SETTINGS.YT_DLP_EXE at the top of the script."
    )
    return
  end

  local audio_format = get_state("audio_format", SETTINGS.DEFAULT_AUDIO_FORMAT)
  local use_project_folder = get_bool_state("use_project_folder", SETTINGS.DEFAULT_USE_PROJECT_FOLDER)
  local saved_folder = get_state("save_folder", "")
  local destination = get_destination(use_project_folder, saved_folder)
  if destination == "" then return end

  if not directory_exists(destination) then
    message("Selected save folder does not exist or cannot be accessed:\n\n" .. destination)
    return
  end

  local url = ask_for_url()
  if url == "" then return end
  if not url:match("^https?://") then
    message("That does not look like a web URL:\n\n" .. url)
    return
  end

  set_state("save_folder", destination)
  local auto_update = get_bool_state("auto_update_yt_dlp", SETTINGS.DEFAULT_AUTO_UPDATE_YT_DLP)
  local ffmpeg_location = find_ffmpeg_location(yt_dlp)
  local insert_after_download = get_bool_state("insert_after_download", SETTINGS.DEFAULT_INSERT_AFTER_DOWNLOAD)
  local insert_track = nil
  local insert_position = reaper.GetCursorPosition()
  if insert_after_download then
    insert_track = reaper.GetSelectedTrack(0, 0)
    if not insert_track then
      local result = reaper.ShowMessageBox(
        "Insert-after-download is enabled, but no track is selected.\n\nDownload without inserting?",
        SCRIPT_NAME,
        4
      )
      if result ~= 6 then return end
      insert_after_download = false
    end
  end
  local log_path = make_log_path("download")
  local temp_dir = os.getenv("TEMP") or destination
  local this_run_id = run_id()
  local final_path_file = temp_dir .. "\\rea_dlp_final_path_" .. this_run_id .. ".txt"
  local status_file = temp_dir .. "\\rea_dlp_status_" .. this_run_id .. ".txt"
  set_state("latest_log", log_path)

  local batch_path = write_download_batch_file(url, destination, audio_format, yt_dlp, ffmpeg_location, log_path, auto_update, final_path_file, status_file)
  if batch_path == "" then
    message("Could not write the temporary download command.")
    return
  end

  launch_batch(batch_path)

  if insert_after_download then
    watch_download_for_insert(final_path_file, status_file, log_path, destination, insert_track, insert_position)
  end
end

local function read_clipboard_url_now()
  local command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Clipboard -Raw"'
  local ok, output = pcall(reaper.ExecProcess, command, 1500)
  if not ok then return "" end
  output = trim((output or ""):gsub("\r", "\n"))
  local url = output:match("(https?://%S+)")
  if url then return trim(url) end
  return ""
end

local gui = {
  url = get_state("last_url", ""),
  playlist_url = get_state("last_playlist_url", ""),
  save_folder = normalize_path(get_state("save_folder", "")),
  use_project_folder = get_bool_state("use_project_folder", SETTINGS.DEFAULT_USE_PROJECT_FOLDER),
  audio_format = get_state("audio_format", SETTINGS.DEFAULT_AUDIO_FORMAT),
  style = get_state("filename_style", ""),
  region = get_state("filename_region", ""),
  channel = get_state("filename_channel", ""),
  artist = get_state("filename_artist", ""),
  year = get_state("filename_year", ""),
  key = get_state("filename_key", ""),
  tempo = get_state("filename_tempo", ""),
  style_filter = "",
  region_filter = "",
  channel_filter = "",
  artist_filter = "",
  year_filter = "",
  key_filter = "",
  tempo_filter = "",
  url_queue = "",
  insert_after_download = get_bool_state("insert_after_download", SETTINGS.DEFAULT_INSERT_AFTER_DOWNLOAD),
  auto_update = get_bool_state("auto_update_yt_dlp", SETTINGS.DEFAULT_AUTO_UPDATE_YT_DLP),
  status = "Ready.",
}

local function save_gui_state()
  set_state("last_url", gui.url)
  set_state("last_playlist_url", gui.playlist_url)
  set_state("save_folder", gui.save_folder)
  set_state("audio_format", gui.audio_format)
  set_state("filename_style", gui.style)
  set_state("filename_region", gui.region)
  set_state("filename_channel", gui.channel)
  set_state("filename_artist", gui.artist)
  set_state("filename_year", gui.year)
  set_state("filename_key", gui.key)
  set_state("filename_tempo", gui.tempo)
  set_bool_state("use_project_folder", gui.use_project_folder)
  set_bool_state("insert_after_download", gui.insert_after_download)
  set_bool_state("auto_update_yt_dlp", gui.auto_update)
end

local function gui_destination()
  if gui.use_project_folder then
    return get_project_folder()
  end
  return normalize_path(gui.save_folder)
end

local function start_gui_download_for_url(download_url, fixed_lane, playlist_mode)
  save_gui_state()
  playlist_mode = playlist_mode == true

  local url = trim(download_url or "")
  if url == "" or not url:match("^https?://") then
    gui.status = "Enter a valid http/https URL."
    return false
  end

  if playlist_mode and not is_playlist_url(url) then
    gui.status = "Enter a YouTube playlist URL."
    return false
  end

  local destination = gui_destination()
  if destination == "" then
    gui.status = gui.use_project_folder and "Save the REAPER project first, or choose a folder." or "Choose an existing save folder."
    return false
  end

  if not directory_exists(destination) then
    gui.status = "Save folder does not exist or cannot be accessed."
    return false
  end

  local yt_dlp = find_yt_dlp()
  if yt_dlp == "" then
    gui.status = "yt-dlp.exe was not found."
    message("Could not find yt-dlp.exe.\n\nPut yt-dlp.exe in the same folder as this script, or set SETTINGS.YT_DLP_EXE.")
    return false
  end

  local insert_track = nil
  local insert_position = reaper.GetCursorPosition()
  if gui.insert_after_download and not playlist_mode then
    insert_track = reaper.GetSelectedTrack(0, 0)
    if not insert_track then
      gui.status = "Select a track before downloading with insert enabled."
      return false
    end
  end

  set_state("save_folder", destination)
  add_to_saved_list("saved_locations", destination)
  add_to_saved_list("saved_styles", gui.style)
  add_to_saved_list("saved_regions", gui.region)
  add_to_saved_list("saved_channels", gui.channel)
  add_to_saved_list("saved_artists", gui.artist)
  add_to_saved_list("saved_years", gui.year)
  add_to_saved_list("saved_keys", gui.key)
  add_to_saved_list("saved_tempos", gui.tempo)

  local ffmpeg_location = find_ffmpeg_location(yt_dlp)
  local log_path = make_log_path("download")
  local temp_dir = os.getenv("TEMP") or destination
  local this_run_id = run_id()
  local final_path_file = temp_dir .. "\\rea_dlp_final_path_" .. this_run_id .. ".txt"
  local status_file = temp_dir .. "\\rea_dlp_status_" .. this_run_id .. ".txt"
  set_state("latest_log", log_path)

  local output_template = playlist_mode and playlist_output_template() or build_output_template(gui.style, gui.region, gui.channel, gui.artist, gui.year, gui.key, gui.tempo)
  local batch_path = write_download_batch_file(url, destination, gui.audio_format, yt_dlp, ffmpeg_location, log_path, gui.auto_update, final_path_file, status_file, output_template, SETTINGS.SHOW_COMMAND_WINDOW, playlist_mode)
  if batch_path == "" then
    gui.status = "Could not write temporary download command."
    return false
  end

  launch_batch(batch_path, SETTINGS.SHOW_COMMAND_WINDOW)
  gui.status = playlist_mode and "Playlist download started." or "Download started."

  if gui.insert_after_download and not playlist_mode then
    watch_download_for_insert(final_path_file, status_file, log_path, destination, insert_track, insert_position, fixed_lane)
  end

  return true
end

local function current_or_clipboard_url()
  local url = trim(gui.url)
  if url ~= "" then return url end

  local clip = read_clipboard_url_now()
  if clip ~= "" then
    gui.url = clip
    return clip
  end

  gui.status = "No URL entered, and clipboard does not contain a valid web URL."
  return ""
end

local function start_gui_download()
  local url = current_or_clipboard_url()
  if url == "" then return end

  if start_gui_download_for_url(url, nil, false) then
    gui.url = ""
    set_state("last_url", "")
  end
end

local function start_gui_playlist_download()
  local url = trim(gui.playlist_url)
  if url == "" then
    url = read_clipboard_url_now()
    if url ~= "" then gui.playlist_url = url end
  end

  if url == "" then
    gui.status = "Enter a playlist URL, or copy one to the clipboard."
    return
  end

  if start_gui_download_for_url(url, nil, true) then
    gui.playlist_url = ""
    set_state("last_playlist_url", "")
  end
end

local function queue_urls()
  local urls = {}
  for line in tostring(gui.url_queue or ""):gmatch("[^\r\n]+") do
    local url = trim(line)
    if url:match("^https?://") then
      urls[#urls + 1] = url
    end
  end
  return urls
end

local function append_url_to_queue(url)
  url = trim(url)
  if url == "" or not url:match("^https?://") then
    gui.status = "Clipboard does not contain a valid web URL."
    return
  end

  if trim(gui.url_queue) == "" then
    gui.url_queue = url
  else
    gui.url_queue = gui.url_queue .. "\n" .. url
  end
  gui.status = "URL added to queue."
end

local function download_all_queued()
  local urls = queue_urls()
  if #urls == 0 then
    gui.status = "Queue has no valid URLs."
    return
  end

  for index, url in ipairs(urls) do
    local lane = gui.insert_after_download and (index - 1) or nil
    start_gui_download_for_url(url, lane, false)
  end

  gui.url_queue = ""
  gui.url = ""
  set_state("last_url", "")
  gui.status = "Queued downloads started: " .. tostring(#urls)
end

local function load_imgui()
  local shim_path = reaper.GetResourcePath() .. "\\Scripts\\ReaTeam Extensions\\API\\imgui.lua"
  local shim_loader = loadfile(shim_path)
  if shim_loader then
    local ok, shim = pcall(shim_loader)
    if ok and type(shim) == "function" then
      pcall(shim, "0.9")
    end
  end

  if not reaper.ImGui_CreateContext then
    message(
      "ReaDLP requires ReaImGui.\n\n" ..
      "Install ReaImGui from ReaPack, then run this script again.\n\n" ..
      "The historical menu version is archived in the stable folder."
    )
    return nil
  end

  return reaper.ImGui_CreateContext(SCRIPT_NAME)
end

local ctx = load_imgui()
if not ctx then return end

local open = true

local function content_width()
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  return tonumber(width) or 0
end

local function should_inline(required_width)
  return content_width() >= required_width
end

local function set_available_item_width(min_width, reserved_width)
  local width = content_width() - (reserved_width or 0)
  reaper.ImGui_SetNextItemWidth(ctx, math.max(min_width or 80, width))
end

local function draw_saved_metadata_row(label, value, state_key, saved_key, filter_value, popup_id, status_label, quick_pairs)
  local inline = should_inline(320)
  local label_width = 72
  local button_width = 48

  reaper.ImGui_Text(ctx, label)
  if inline then
    reaper.ImGui_SameLine(ctx, label_width)
    set_available_item_width(90, button_width + button_width + 22)
  else
    set_available_item_width(90, 0)
  end

  local changed
  changed, value = reaper.ImGui_InputText(ctx, "##" .. state_key, value)
  if changed then set_state(state_key, value) end

  if inline then reaper.ImGui_SameLine(ctx) end
  if reaper.ImGui_Button(ctx, "Find##find_" .. state_key, button_width, 0) then
    reaper.ImGui_OpenPopup(ctx, popup_id)
  end

  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Save##save_" .. state_key, button_width, 0) then
    add_to_saved_list(saved_key, value)
    gui.status = status_label .. " saved."
  end

  if reaper.ImGui_BeginPopup(ctx, popup_id) then
    local filter_changed
    filter_changed, filter_value = reaper.ImGui_InputText(ctx, "Search##filter_" .. state_key, filter_value)
    local filter = trim(filter_value):lower()

    if quick_pairs then
      reaper.ImGui_Text(ctx, "Major")
      reaper.ImGui_SameLine(ctx, 90)
      reaper.ImGui_Text(ctx, "Relative minor")

      for index, pair in ipairs(quick_pairs) do
        if filter == "" or pair.major:lower():find(filter, 1, true) or pair.minor:lower():find(filter, 1, true) then
          if reaper.ImGui_Button(ctx, pair.major .. " ##major_" .. state_key .. "_" .. tostring(index), 64, 0) then
            value = pair.major
            set_state(state_key, value)
            reaper.ImGui_CloseCurrentPopup(ctx)
          end

          reaper.ImGui_SameLine(ctx, 90)
          if reaper.ImGui_Button(ctx, pair.minor .. " ##minor_" .. state_key .. "_" .. tostring(index), 64, 0) then
            value = pair.minor
            set_state(state_key, value)
            reaper.ImGui_CloseCurrentPopup(ctx)
          end
        end
      end

      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Text(ctx, "Saved")
    end

    local saved_items = split_list(get_state(saved_key, ""))
    for _, item in ipairs(saved_items) do
      if filter == "" or item:lower():find(filter, 1, true) then
        if reaper.ImGui_Selectable(ctx, item, item == value) then
          value = item
          set_state(state_key, value)
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end

  return value, filter_value
end

local function draw_gui()
  reaper.ImGui_SetNextWindowSize(ctx, 560, 500, reaper.ImGui_Cond_FirstUseEver())
  local visible
  visible, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, open)

  if visible then
    local changed
    if reaper.ImGui_BeginTabBar(ctx, "rea_dlp_tabs") then
      if reaper.ImGui_BeginTabItem(ctx, "Download") then
        reaper.ImGui_Text(ctx, "URL")
        local inline_url = should_inline(340)
        set_available_item_width(120, inline_url and 130 or 0)
        changed, gui.url = reaper.ImGui_InputText(ctx, "##url", gui.url)
        if changed then set_state("last_url", gui.url) end
        if inline_url then reaper.ImGui_SameLine(ctx) end
        if reaper.ImGui_Button(ctx, "Clipboard", 120, 0) then
          local clipboard_url = read_clipboard_url_now()
          if clipboard_url ~= "" then
            gui.url = clipboard_url
            set_state("last_url", gui.url)
            gui.status = "URL copied from clipboard."
          else
            gui.status = "Clipboard does not contain a valid web URL."
          end
        end

        if reaper.ImGui_Button(ctx, "Download") then start_gui_download() end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Insert Latest") then
          insert_latest_download_on_selected_track()
          gui.status = "Insert latest requested."
        end

        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, "Playlist URL")
        local inline_playlist_url = should_inline(340)
        set_available_item_width(120, inline_playlist_url and 130 or 0)
        changed, gui.playlist_url = reaper.ImGui_InputText(ctx, "##playlist_url", gui.playlist_url)
        if changed then set_state("last_playlist_url", gui.playlist_url) end
        if inline_playlist_url then reaper.ImGui_SameLine(ctx) end
        if reaper.ImGui_Button(ctx, "Clipboard##playlist_clipboard", 120, 0) then
          local clipboard_url = read_clipboard_url_now()
          if clipboard_url ~= "" then
            gui.playlist_url = clipboard_url
            set_state("last_playlist_url", gui.playlist_url)
            gui.status = "Playlist URL copied from clipboard."
          else
            gui.status = "Clipboard does not contain a valid web URL."
          end
        end

        if reaper.ImGui_Button(ctx, "Download Playlist") then
          start_gui_playlist_download()
        end

        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, "Queue")
        changed, gui.url_queue = reaper.ImGui_InputTextMultiline(ctx, "##url_queue", gui.url_queue, -1, 120)

        if reaper.ImGui_Button(ctx, "Add Clipboard URL to Queue") then
          append_url_to_queue(read_clipboard_url_now())
        end
        if reaper.ImGui_Button(ctx, "Download All Queued") then
          download_all_queued()
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Clear Queue") then
          gui.url_queue = ""
          gui.status = "Queue cleared."
        end

        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "Metadata") then
        gui.style, gui.style_filter = draw_saved_metadata_row("Style", gui.style, "filename_style", "saved_styles", gui.style_filter, "style_search_popup", "Style")
        gui.region, gui.region_filter = draw_saved_metadata_row("Region", gui.region, "filename_region", "saved_regions", gui.region_filter, "region_search_popup", "Region")
        gui.channel, gui.channel_filter = draw_saved_metadata_row("Channel", gui.channel, "filename_channel", "saved_channels", gui.channel_filter, "channel_search_popup", "Channel")
        gui.artist, gui.artist_filter = draw_saved_metadata_row("Artist", gui.artist, "filename_artist", "saved_artists", gui.artist_filter, "artist_search_popup", "Artist")
        gui.year, gui.year_filter = draw_saved_metadata_row("Year", gui.year, "filename_year", "saved_years", gui.year_filter, "year_search_popup", "Year")
        gui.key, gui.key_filter = draw_saved_metadata_row("Key", gui.key, "filename_key", "saved_keys", gui.key_filter, "key_search_popup", "Key", KEY_PAIRS)
        gui.tempo, gui.tempo_filter = draw_saved_metadata_row("Tempo", gui.tempo, "filename_tempo", "saved_tempos", gui.tempo_filter, "tempo_search_popup", "Tempo")

        reaper.ImGui_Separator(ctx)
        reaper.ImGui_TextWrapped(ctx, "Filename: " .. build_output_template(gui.style, gui.region, gui.channel, gui.artist, gui.year, gui.key, gui.tempo))
        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "Location") then
        changed, gui.use_project_folder = reaper.ImGui_Checkbox(ctx, "Use saved REAPER project folder", gui.use_project_folder)
        if changed then set_bool_state("use_project_folder", gui.use_project_folder) end

        reaper.ImGui_Text(ctx, "Save folder")
        set_available_item_width(120, 0)
        changed, gui.save_folder = reaper.ImGui_InputText(ctx, "##save_folder", gui.save_folder)
        if changed then set_state("save_folder", normalize_path(gui.save_folder)) end

        reaper.ImGui_Text(ctx, "Saved locations")
        local saved_location_label = gui.save_folder ~= "" and gui.save_folder or "Saved locations"
        set_available_item_width(120, 0)
        if reaper.ImGui_BeginCombo(ctx, "##saved_locations", saved_location_label) then
          local locations = split_list(get_state("saved_locations", ""))
          for _, folder in ipairs(locations) do
            if reaper.ImGui_Selectable(ctx, folder, folder == gui.save_folder) then
              gui.save_folder = folder
              gui.use_project_folder = false
              save_gui_state()
            end
          end
          reaper.ImGui_EndCombo(ctx)
        end

        if reaper.ImGui_Button(ctx, "Choose Folder") then
          local folder = ask_for_folder(gui.save_folder)
          if folder ~= "" then
            gui.save_folder = folder
            gui.use_project_folder = false
            add_to_saved_list("saved_locations", folder)
            save_gui_state()
          end
        end

        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Save Location") then
          add_to_saved_list("saved_locations", gui.save_folder)
          gui.status = "Location saved."
        end

        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Validate") then
          local destination = gui_destination()
          gui.status = directory_exists(destination) and "Save folder exists." or "Save folder missing or inaccessible."
        end

        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "Tools") then
        reaper.ImGui_Text(ctx, "Audio format")
        set_available_item_width(120, 0)
        if reaper.ImGui_BeginCombo(ctx, "##audio_format", format_label(gui.audio_format)) then
          for _, item in ipairs(FORMAT_CHOICES) do
            local selected = item.value == gui.audio_format
            if reaper.ImGui_Selectable(ctx, item.label, selected) then
              gui.audio_format = item.value
              set_state("audio_format", gui.audio_format)
            end
          end
          reaper.ImGui_EndCombo(ctx)
        end

        changed, gui.insert_after_download = reaper.ImGui_Checkbox(ctx, "Insert downloaded audio on selected track", gui.insert_after_download)
        if changed then set_bool_state("insert_after_download", gui.insert_after_download) end

        changed, gui.auto_update = reaper.ImGui_Checkbox(ctx, "Auto-update yt-dlp before download", gui.auto_update)
        if changed then set_bool_state("auto_update_yt_dlp", gui.auto_update) end

        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Button(ctx, "Update yt-dlp") then
          run_update()
          gui.status = "Update command started."
        end
        if reaper.ImGui_Button(ctx, "Copy Latest Log") then copy_latest_log_to_clipboard() end
        if reaper.ImGui_Button(ctx, "Tool Diagnostics") then copy_tool_diagnostics_to_clipboard() end
        if reaper.ImGui_Button(ctx, "Folder Diagnostics") then copy_save_folder_diagnostics_to_clipboard() end
        if reaper.ImGui_Button(ctx, "Open Logs") then open_logs_folder() end

        reaper.ImGui_EndTabItem(ctx)
      end

      if reaper.ImGui_BeginTabItem(ctx, "Status") then
        reaper.ImGui_TextWrapped(ctx, "Status: " .. gui.status)
        local latest_log = get_state("latest_log", "")
        if latest_log ~= "" then
          reaper.ImGui_TextWrapped(ctx, "Latest log: " .. latest_log)
        end
        reaper.ImGui_EndTabItem(ctx)
      end

      reaper.ImGui_EndTabBar(ctx)
    end

    reaper.ImGui_End(ctx)
  end

  if open then
    reaper.defer(draw_gui)
  end
end

reaper.defer(draw_gui)
