use crate::config::{ConfigResolution, Configuration, FloatWindowRule, StatusCommand};
use crate::layout::{
    inset_area, mirror_tall_layout, mirror_tall_layout_with_gaps, tall_layout,
    tall_layout_with_gaps, Rect,
};
use crate::manager::{CandidateWindow, ManagerActionOutput, ManagerCore, ScreenSpec, WindowEffect};
use crate::screen_geometry::{
    accessibility_frame, is_parked_window_frame, is_session_locked, matches_visible_window,
    parked_window_origin, VisibleWindowCandidate,
};
use crate::status_commands::StatusCommandsEngine;
use crate::status_markup::{
     parse_status_markup, read_custom_status, render_status, template_status_parts, write_status,
    SpaceEntry, StatusPart, StatusSegmentStyle, StatusValues,
};
use crate::virtual_workspaces::{
    write_atomic_0600, PersistedWorkspaceSession, WorkspaceLayoutState,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::path::{Path, PathBuf};
use toml_edit::{DocumentMut, Item, Value};

fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(ptr).to_str().ok() }
    }
}

fn into_c_string(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

fn write_error(out_error: *mut *mut c_char, msg: String) {
    if !out_error.is_null() {
        unsafe {
            *out_error = into_c_string(msg);
        }
    }
}

#[no_mangle]
pub extern "C" fn talus_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

// MARK: - Layout & Screen Geometry FFI

#[no_mangle]
pub extern "C" fn talus_inset_area(area: Rect, outer_gap: f64) -> Rect {
    inset_area(area, outer_gap)
}

#[no_mangle]
pub extern "C" fn talus_tall_layout(
    area: Rect,
    count: usize,
    masters: usize,
    ratio: f64,
    out_rects: *mut Rect,
) -> usize {
    let rects = tall_layout(area, count, masters, ratio);
    if !out_rects.is_null() {
        for (i, r) in rects.iter().enumerate() {
            unsafe {
                *out_rects.add(i) = *r;
            }
        }
    }
    rects.len()
}

#[no_mangle]
pub extern "C" fn talus_tall_layout_with_gaps(
    area: Rect,
    count: usize,
    masters: usize,
    ratio: f64,
    outer_gap: f64,
    inner_gap: f64,
    out_rects: *mut Rect,
) -> usize {
    let rects = tall_layout_with_gaps(area, count, masters, ratio, outer_gap, inner_gap);
    if !out_rects.is_null() {
        for (i, r) in rects.iter().enumerate() {
            unsafe {
                *out_rects.add(i) = *r;
            }
        }
    }
    rects.len()
}

#[no_mangle]
pub extern "C" fn talus_mirror_tall_layout(
    area: Rect,
    count: usize,
    masters: usize,
    ratio: f64,
    out_rects: *mut Rect,
) -> usize {
    let rects = mirror_tall_layout(area, count, masters, ratio);
    if !out_rects.is_null() {
        for (i, r) in rects.iter().enumerate() {
            unsafe {
                *out_rects.add(i) = *r;
            }
        }
    }
    rects.len()
}

#[no_mangle]
pub extern "C" fn talus_mirror_tall_layout_with_gaps(
    area: Rect,
    count: usize,
    masters: usize,
    ratio: f64,
    outer_gap: f64,
    inner_gap: f64,
    out_rects: *mut Rect,
) -> usize {
    let rects = mirror_tall_layout_with_gaps(area, count, masters, ratio, outer_gap, inner_gap);
    if !out_rects.is_null() {
        for (i, r) in rects.iter().enumerate() {
            unsafe {
                *out_rects.add(i) = *r;
            }
        }
    }
    rects.len()
}

#[no_mangle]
pub extern "C" fn talus_accessibility_frame(visible: Rect, primary_top: f64) -> Rect {
    accessibility_frame(visible, primary_top)
}

#[no_mangle]
pub extern "C" fn talus_parked_window_origin(
    window_w: f64,
    window_h: f64,
    screen: Rect,
    all_screens_ptr: *const Rect,
    all_screens_len: usize,
    out_x: *mut f64,
    out_y: *mut f64,
) {
    let all_screens = if all_screens_ptr.is_null() || all_screens_len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(all_screens_ptr, all_screens_len) }
    };
    let (x, y) = parked_window_origin(window_w, window_h, screen, all_screens);
    if !out_x.is_null() {
        unsafe { *out_x = x };
    }
    if !out_y.is_null() {
        unsafe { *out_y = y };
    }
}

#[no_mangle]
pub extern "C" fn talus_is_parked_window_frame(frame: Rect, screen: Rect) -> bool {
    is_parked_window_frame(frame, screen)
}

#[no_mangle]
pub extern "C" fn talus_matches_visible_window(
    pid: i32,
    has_ax_wid: bool,
    ax_wid: u32,
    ax_frame: Rect,
    candidates_json: *const c_char,
) -> bool {
    let Some(json_str) = cstr_to_str(candidates_json) else {
        return false;
    };
    let Ok(candidates) = serde_json::from_str::<Vec<VisibleWindowCandidate>>(json_str) else {
        return false;
    };
    let wid = if has_ax_wid { Some(ax_wid) } else { None };
    matches_visible_window(pid, wid, ax_frame, &candidates)
}

#[no_mangle]
pub extern "C" fn talus_is_session_locked(
    has_screen_locked: bool,
    screen_locked: bool,
    has_on_console: bool,
    on_console: bool,
    frontmost_bundle_id: *const c_char,
) -> bool {
    let sl = if has_screen_locked {
        Some(screen_locked)
    } else {
        None
    };
    let oc = if has_on_console {
        Some(on_console)
    } else {
        None
    };
    let fb = cstr_to_str(frontmost_bundle_id);
    is_session_locked(sl, oc, fb)
}

// MARK: - TOML & Configuration FFI

fn toml_value_to_typed_json(val: &Value) -> serde_json::Value {
    match val {
        Value::String(s) => serde_json::json!({ "type": "string", "value": s.value() }),
        Value::Integer(i) => serde_json::json!({ "type": "int", "value": i.value() }),
        Value::Float(f) => serde_json::json!({ "type": "double", "value": f.value() }),
        Value::Boolean(b) => serde_json::json!({ "type": "bool", "value": b.value() }),
        Value::Datetime(dt) => {
            serde_json::json!({ "type": "string", "value": dt.value().to_string() })
        }
        Value::Array(arr) => {
            let elems: Vec<serde_json::Value> =
                arr.iter().map(toml_value_to_typed_json).collect();
            serde_json::json!({ "type": "array", "value": elems })
        }
        Value::InlineTable(tbl) => {
            let mut map = serde_json::Map::new();
            for (k, v) in tbl.iter() {
                map.insert(k.to_string(), toml_value_to_typed_json(v));
            }
            serde_json::json!({ "type": "table", "value": map })
        }
    }
}

fn toml_item_to_typed_json(item: &Item) -> serde_json::Value {
    match item {
        Item::Value(v) => toml_value_to_typed_json(v),
        Item::Table(t) => {
            let mut map = serde_json::Map::new();
            for (k, v) in t.iter() {
                map.insert(k.to_string(), toml_item_to_typed_json(v));
            }
            serde_json::json!({ "type": "table", "value": map })
        }
        Item::ArrayOfTables(aot) => {
            let elems: Vec<serde_json::Value> = aot
                .iter()
                .map(|t| {
                    let mut map = serde_json::Map::new();
                    for (k, v) in t.iter() {
                        map.insert(k.to_string(), toml_item_to_typed_json(v));
                    }
                    serde_json::json!({ "type": "table", "value": map })
                })
                .collect();
            serde_json::json!({ "type": "array", "value": elems })
        }
        Item::None => serde_json::Value::Null,
    }
}

#[no_mangle]
pub extern "C" fn talus_toml_parse_json(
    source: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut c_char {
    let Some(src) = cstr_to_str(source) else {
        write_error(out_error, "invalid UTF-8 string".to_string());
        return std::ptr::null_mut();
    };
    match src.parse::<DocumentMut>() {
        Ok(doc) => {
            let typed = toml_item_to_typed_json(doc.as_item());
            match serde_json::to_string(&typed) {
                Ok(s) => into_c_string(s),
                Err(e) => {
                    write_error(out_error, e.to_string());
                    std::ptr::null_mut()
                }
            }
        }
        Err(e) => {
            write_error(out_error, e.to_string());
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn talus_config_decode_toml_json(
    source: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut c_char {
    let Some(src) = cstr_to_str(source) else {
        write_error(out_error, "invalid UTF-8 string".to_string());
        return std::ptr::null_mut();
    };
    match Configuration::decode_toml(src) {
        Ok(cfg) => match serde_json::to_string(&cfg) {
            Ok(s) => into_c_string(s),
            Err(e) => {
                write_error(out_error, e.to_string());
                std::ptr::null_mut()
            }
        },
        Err(e) => {
            write_error(out_error, e);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn talus_config_validate_json(
    config_json: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    let Some(json_str) = cstr_to_str(config_json) else {
        write_error(out_error, "invalid UTF-8".to_string());
        return false;
    };
    let cfg: Configuration = match serde_json::from_str(json_str) {
        Ok(c) => c,
        Err(e) => {
            write_error(out_error, e.to_string());
            return false;
        }
    };
    match cfg.validate() {
        Ok(()) => true,
        Err(e) => {
            write_error(out_error, e);
            false
        }
    }
}

#[no_mangle]
pub extern "C" fn talus_config_to_toml(
    config_json: *const c_char,
    existing_toml: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut c_char {
    let Some(json_str) = cstr_to_str(config_json) else {
        write_error(out_error, "invalid UTF-8".to_string());
        return std::ptr::null_mut();
    };
    let cfg: Configuration = match serde_json::from_str(json_str) {
        Ok(c) => c,
        Err(e) => {
            write_error(out_error, e.to_string());
            return std::ptr::null_mut();
        }
    };
    let existing = cstr_to_str(existing_toml);
    into_c_string(cfg.to_toml_preserving_comments(existing))
}

#[no_mangle]
pub extern "C" fn talus_config_load_path_json(
    path: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut c_char {
    let Some(p) = cstr_to_str(path) else {
        write_error(out_error, "invalid path".to_string());
        return std::ptr::null_mut();
    };
    match Configuration::load_from_path(Path::new(p)) {
        Ok(cfg) => match serde_json::to_string(&cfg) {
            Ok(s) => into_c_string(s),
            Err(e) => {
                write_error(out_error, e.to_string());
                std::ptr::null_mut()
            }
        },
        Err(e) => {
            write_error(out_error, e);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn talus_config_save_path_json(
    config_json: *const c_char,
    path: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    let (Some(json_str), Some(p)) = (cstr_to_str(config_json), cstr_to_str(path)) else {
        write_error(out_error, "invalid arguments".to_string());
        return false;
    };
    let cfg: Configuration = match serde_json::from_str(json_str) {
        Ok(c) => c,
        Err(e) => {
            write_error(out_error, e.to_string());
            return false;
        }
    };
    match cfg.save_to_path(Path::new(p)) {
        Ok(()) => true,
        Err(e) => {
            write_error(out_error, e);
            false
        }
    }
}

#[no_mangle]
pub extern "C" fn talus_float_rule_matches(
    rule_json: *const c_char,
    bundle_id: *const c_char,
    window_title: *const c_char,
) -> bool {
    let Some(rj) = cstr_to_str(rule_json) else {
        return false;
    };
    let Ok(rule) = serde_json::from_str::<FloatWindowRule>(rj) else {
        return false;
    };
    let b = cstr_to_str(bundle_id);
    let t = cstr_to_str(window_title).unwrap_or("");
    rule.matches(b, t)
}

#[no_mangle]
pub extern "C" fn talus_resolve_paths_json(
    home_dir: *const c_char,
    talus_config_env: *const c_char,
    existing_paths_json: *const c_char,
) -> *mut c_char {
    let home = cstr_to_str(home_dir).unwrap_or("");
    let env_val = cstr_to_str(talus_config_env);
    let existing: Option<Vec<String>> = cstr_to_str(existing_paths_json)
        .and_then(|s| serde_json::from_str(s).ok());
    let res: ConfigResolution = if let Some(list) = existing {
        Configuration::resolve_paths(home, env_val, |p| list.iter().any(|x| x == p))
    } else {
        Configuration::resolve_paths(home, env_val, |p| Path::new(p).exists())
    };
    into_c_string(serde_json::to_string(&res).unwrap_or_default())
}

// MARK: - Status Text, Markup & Export FFI

#[no_mangle]
pub extern "C" fn talus_write_atomic_0600(
    bytes: *const u8,
    len: usize,
    path: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    let Some(p) = cstr_to_str(path) else {
        write_error(out_error, "invalid path".to_string());
        return false;
    };
    let data = if bytes.is_null() || len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, len) }
    };
    match write_status(data, Path::new(p)) {
        Ok(()) => true,
        Err(e) => {
            write_error(out_error, e);
            false
        }
    }
}

#[no_mangle]
pub extern "C" fn talus_read_custom_status(path: *const c_char) -> *mut c_char {
    let Some(p) = cstr_to_str(path) else {
        return into_c_string(String::new());
    };
    into_c_string(read_custom_status(p))
}

#[no_mangle]
pub extern "C" fn talus_render_status_json(
    format: *const c_char,
    values_json: *const c_char,
) -> *mut c_char {
    let (Some(fmt), Some(vj)) = (cstr_to_str(format), cstr_to_str(values_json)) else {
        return into_c_string(String::new());
    };
    let Ok(values) = serde_json::from_str::<StatusValues>(vj) else {
        return into_c_string(String::new());
    };
    into_c_string(render_status(fmt, &values))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParseMarkupRequest {
    source: String,
    fonts: Vec<String>,
    font_size: f64,
    initial: Option<StatusSegmentStyle>,
    current: bool,
    workspace_index: Option<usize>,
}

#[no_mangle]
pub extern "C" fn talus_parse_status_markup_json(request_json: *const c_char) -> *mut c_char {
    let Some(rj) = cstr_to_str(request_json) else {
        return into_c_string("[]".to_string());
    };
    let Ok(req) = serde_json::from_str::<ParseMarkupRequest>(rj) else {
        return into_c_string("[]".to_string());
    };
    let parts: Vec<StatusPart> = parse_status_markup(
        &req.source,
        &req.fonts,
        req.font_size,
        req.initial,
        req.current,
        req.workspace_index,
        |_, _| None,
    );
    into_c_string(serde_json::to_string(&parts).unwrap_or_else(|_| "[]".to_string()))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TemplateStatusRequest {
    config: Configuration,
    values: StatusValues,
    command_outputs: Vec<String>,
}

#[no_mangle]
pub extern "C" fn talus_template_status_parts_json(request_json: *const c_char) -> *mut c_char {
    let Some(rj) = cstr_to_str(request_json) else {
        return into_c_string("[]".to_string());
    };
    let Ok(req) = serde_json::from_str::<TemplateStatusRequest>(rj) else {
        return into_c_string("[]".to_string());
    };
    let parts = template_status_parts(&req.config, &req.values, |idx| {
        req.command_outputs.get(idx).cloned().unwrap_or_default()
    });
    into_c_string(serde_json::to_string(&parts).unwrap_or_else(|_| "[]".to_string()))
}

// MARK: - StatusCommandsEngine FFI

pub struct TalusStatusCommandsHandle {
    engine: StatusCommandsEngine,
}

#[no_mangle]
pub extern "C" fn talus_status_commands_new(
    state_file: *const c_char,
    on_change: Option<extern "C" fn(*mut c_void)>,
    ctx: *mut c_void,
) -> *mut TalusStatusCommandsHandle {
    let sf = cstr_to_str(state_file).map(|s| s.to_string());
    let ctx_addr = ctx as usize;
    let cb: Option<Box<dyn Fn() + Send + Sync>> = on_change.map(|func| {
        Box::new(move || {
            func(ctx_addr as *mut c_void);
        }) as Box<dyn Fn() + Send + Sync>
    });
    let handle = Box::new(TalusStatusCommandsHandle {
        engine: StatusCommandsEngine::new(sf, cb),
    });
    Box::into_raw(handle)
}

#[no_mangle]
pub extern "C" fn talus_status_commands_free(handle: *mut TalusStatusCommandsHandle) {
    if !handle.is_null() {
        unsafe {
            let h = Box::from_raw(handle);
            h.engine.stop_all();
        }
    }
}

#[no_mangle]
pub extern "C" fn talus_status_commands_set_state_json(
    handle: *mut TalusStatusCommandsHandle,
    state_json: *const c_char,
) {
    if handle.is_null() {
        return;
    }
    let h = unsafe { &*handle };
    h.engine
        .set_state_json(cstr_to_str(state_json).map(|s| s.to_string()));
}

#[no_mangle]
pub extern "C" fn talus_status_commands_get_state_json(
    handle: *mut TalusStatusCommandsHandle,
) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*handle };
    match h.engine.get_state_json() {
        Some(s) => into_c_string(s),
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn talus_status_commands_value(
    handle: *mut TalusStatusCommandsHandle,
    index: usize,
    command_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        return into_c_string(String::new());
    }
    let Some(cj) = cstr_to_str(command_json) else {
        return into_c_string(String::new());
    };
    let Ok(cmd) = serde_json::from_str::<StatusCommand>(cj) else {
        return into_c_string(String::new());
    };
    let h = unsafe { &*handle };
    into_c_string(h.engine.value(index, &cmd))
}

#[no_mangle]
pub extern "C" fn talus_status_commands_state_changed(
    handle: *mut TalusStatusCommandsHandle,
    commands_json: *const c_char,
) {
    if handle.is_null() {
        return;
    }
    let Some(cj) = cstr_to_str(commands_json) else {
        return;
    };
    let Ok(cmds) = serde_json::from_str::<Vec<StatusCommand>>(cj) else {
        return;
    };
    let h = unsafe { &*handle };
    h.engine.state_changed(&cmds);
}

#[no_mangle]
pub extern "C" fn talus_status_commands_is_running(
    handle: *mut TalusStatusCommandsHandle,
    index: usize,
) -> bool {
    if handle.is_null() {
        return false;
    }
    let h = unsafe { &*handle };
    h.engine.is_running(index)
}

#[no_mangle]
pub extern "C" fn talus_status_commands_stop_all(handle: *mut TalusStatusCommandsHandle) {
    if handle.is_null() {
        return;
    }
    let h = unsafe { &*handle };
    h.engine.stop_all();
}

// MARK: - ManagerCore FFI

pub struct TalusManagerHandle {
    core: ManagerCore,
}

fn deserialize_u64_rect_map<'de, D>(deserializer: D) -> Result<HashMap<u64, Rect>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw = HashMap::<String, Rect>::deserialize(deserializer)?;
    let mut out = HashMap::with_capacity(raw.len());
    for (k, v) in raw {
        let parsed = k
            .parse::<u64>()
            .map_err(|_| serde::de::Error::custom(format!("invalid u64 map key: {}", k)))?;
        out.insert(parsed, v);
    }
    Ok(out)
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum ManagerRequest {
    #[serde(rename_all = "camelCase")]
    Refresh {
        force: bool,
        now: f64,
        screens: Vec<ScreenSpec>,
        candidates: Vec<CandidateWindow>,
        busy_pids: Vec<i32>,
        visible_window_ids: Vec<u32>,
        all_existing_cg_window_ids: Vec<u32>,
        dead_history_keys: Vec<u64>,
        eligible_visible_window_exists: bool,
        frontmost_key: Option<u64>,
        trace_events: bool,
    },
    #[serde(rename_all = "camelCase")]
    HandleKey {
        code: u32,
        shift: bool,
        now: f64,
        trusted: bool,
        frontmost_key: Option<u64>,
        #[serde(deserialize_with = "deserialize_u64_rect_map")]
        live_frames: HashMap<u64, Rect>,
    },
    #[serde(rename_all = "camelCase")]
    SwitchWorkspace {
        index: usize,
        now: f64,
        trusted: bool,
        frontmost_key: Option<u64>,
        #[serde(deserialize_with = "deserialize_u64_rect_map")]
        live_frames: HashMap<u64, Rect>,
    },
    #[serde(rename_all = "camelCase")]
    MoveWindowToWorkspace {
        index: usize,
        now: f64,
        trusted: bool,
        frontmost_key: Option<u64>,
        #[serde(deserialize_with = "deserialize_u64_rect_map")]
        live_frames: HashMap<u64, Rect>,
    },
    #[serde(rename_all = "camelCase")]
    HandleAxFocusNotification {
        now: f64,
        trusted: bool,
        locked: bool,
        frontmost_key: Option<u64>,
        #[serde(deserialize_with = "deserialize_u64_rect_map")]
        live_frames: HashMap<u64, Rect>,
    },
    #[serde(rename_all = "camelCase")]
    HandleApplicationActivated {
        pid: i32,
        now: f64,
        trusted: bool,
        locked: bool,
        app_focused_key: Option<u64>,
        #[serde(deserialize_with = "deserialize_u64_rect_map")]
        live_frames: HashMap<u64, Rect>,
    },
    #[serde(rename_all = "camelCase")]
    ApplyConfig {
        config: Configuration,
        now: f64,
        trusted: bool,
        frontmost_key: Option<u64>,
        #[serde(deserialize_with = "deserialize_u64_rect_map")]
        live_frames: HashMap<u64, Rect>,
    },
    #[serde(rename_all = "camelCase")]
    RestoreAllParkedWindows {
        trusted: bool,
        #[serde(deserialize_with = "deserialize_u64_rect_map")]
        live_frames: HashMap<u64, Rect>,
    },
    #[serde(rename_all = "camelCase")]
    RecordCurrentSessionState,
    #[serde(rename_all = "camelCase")]
    RememberFocus {
        now: f64,
        frontmost_key: Option<u64>,
    },
    #[serde(rename_all = "camelCase")]
    SetPaused { paused: bool },
    #[serde(rename_all = "camelCase")]
    GetStatusSnapshot {
        now: f64,
        frontmost_key: Option<u64>,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ManagerStatusSnapshot {
    is_virtual_mode: bool,
    paused: bool,
    layout_name: String,
    active_workspace: usize,
    workspace_count: usize,
    window_count: usize,
    focused_window_key: Option<u64>,
    focused_screen_id: Option<usize>,
    virtual_space_entries: Vec<SpaceEntry>,
}

#[no_mangle]
pub extern "C" fn talus_manager_new(
    config_json: *const c_char,
    session_file_path: *const c_char,
) -> *mut TalusManagerHandle {
    let cfg: Configuration = cstr_to_str(config_json)
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();
    let session_path = cstr_to_str(session_file_path)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from);
    let handle = Box::new(TalusManagerHandle {
        core: ManagerCore::new(&cfg, session_path),
    });
    Box::into_raw(handle)
}

#[no_mangle]
pub extern "C" fn talus_manager_free(handle: *mut TalusManagerHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}

#[no_mangle]
pub extern "C" fn talus_manager_dispatch(
    handle: *mut TalusManagerHandle,
    request_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        return into_c_string("{}".to_string());
    }
    let Some(rj) = cstr_to_str(request_json) else {
        return into_c_string("{}".to_string());
    };
    let req: ManagerRequest = match serde_json::from_str(rj) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("talus_manager_dispatch decode error: {}", e);
            return into_c_string("{}".to_string());
        }
    };
    let core = unsafe { &mut (*handle).core };
    match req {
        ManagerRequest::Refresh {
            force,
            now,
            screens,
            candidates,
            busy_pids,
            visible_window_ids,
            all_existing_cg_window_ids,
            dead_history_keys,
            eligible_visible_window_exists,
            frontmost_key,
            trace_events,
        } => {
            let out = core.refresh(
                force,
                now,
                screens,
                candidates,
                &busy_pids,
                &visible_window_ids,
                &all_existing_cg_window_ids,
                &[],
                &dead_history_keys,
                eligible_visible_window_exists,
                frontmost_key,
                trace_events,
            );
            into_c_string(serde_json::to_string(&out).unwrap_or_default())
        }
        ManagerRequest::HandleKey {
            code,
            shift,
            now,
            trusted,
            frontmost_key,
            live_frames,
        } => {
            let out = core.handle_key(code, shift, now, trusted, frontmost_key, &live_frames);
            into_c_string(serde_json::to_string(&out).unwrap_or_default())
        }
        ManagerRequest::SwitchWorkspace {
            index,
            now,
            trusted,
            frontmost_key,
            live_frames,
        } => {
            let out = core.switch_workspace(index, now, trusted, frontmost_key, &live_frames);
            into_c_string(serde_json::to_string(&out).unwrap_or_default())
        }
        ManagerRequest::MoveWindowToWorkspace {
            index,
            now,
            trusted,
            frontmost_key,
            live_frames,
        } => {
            let out =
                core.move_window_to_workspace(index, now, trusted, frontmost_key, &live_frames);
            into_c_string(serde_json::to_string(&out).unwrap_or_default())
        }
        ManagerRequest::HandleAxFocusNotification {
            now,
            trusted,
            locked,
            frontmost_key,
            live_frames,
        } => {
            let out = core.handle_ax_focus_notification(
                now,
                trusted,
                locked,
                frontmost_key,
                &live_frames,
            );
            into_c_string(serde_json::to_string(&out).unwrap_or_default())
        }
        ManagerRequest::HandleApplicationActivated {
            pid,
            now,
            trusted,
            locked,
            app_focused_key,
            live_frames,
        } => {
            let out = core.handle_application_activated(
                pid,
                now,
                trusted,
                locked,
                app_focused_key,
                &live_frames,
            );
            into_c_string(serde_json::to_string(&out).unwrap_or_default())
        }
        ManagerRequest::ApplyConfig {
            config,
            now,
            trusted,
            frontmost_key,
            live_frames,
        } => {
            let out = core.apply_config(&config, now, trusted, frontmost_key, &live_frames);
            into_c_string(serde_json::to_string(&out).unwrap_or_default())
        }
        ManagerRequest::RestoreAllParkedWindows {
            trusted,
            live_frames,
        } => {
            let effects: Vec<WindowEffect> =
                core.restore_all_parked_windows(trusted, &live_frames);
            let mut out = ManagerActionOutput::default();
            out.effects = effects;
            into_c_string(serde_json::to_string(&out).unwrap_or_default())
        }
        ManagerRequest::RecordCurrentSessionState => {
            core.record_current_session_state();
            core.flush_session();
            into_c_string("{}".to_string())
        }
        ManagerRequest::RememberFocus { now, frontmost_key } => {
            core.remember_focus(now, frontmost_key);
            into_c_string("{}".to_string())
        }
        ManagerRequest::SetPaused { paused } => {
            core.paused = paused;
            let out = ManagerActionOutput {
                paused: core.paused,
                layout_name: core.layout_name().to_string(),
                active_workspace: core.virtual_engine.active,
                workspace_count: core.virtual_engine.count,
                is_virtual_mode: core.is_virtual_mode(),
                ..Default::default()
            };
            into_c_string(serde_json::to_string(&out).unwrap_or_default())
        }
        ManagerRequest::GetStatusSnapshot { now, frontmost_key } => {
            let focused_idx = core.focused_index(now, frontmost_key);
            let focused_win = focused_idx.and_then(|i| core.windows.get(i));
            let snap = ManagerStatusSnapshot {
                is_virtual_mode: core.is_virtual_mode(),
                paused: core.paused,
                layout_name: core.layout_name().to_string(),
                active_workspace: core.virtual_engine.active,
                workspace_count: core.virtual_engine.count,
                window_count: core.windows.len(),
                focused_window_key: focused_win.map(|w| w.key),
                focused_screen_id: focused_win.map(|w| w.screen_id),
                virtual_space_entries: core.virtual_space_entries(),
            };
            into_c_string(serde_json::to_string(&snap).unwrap_or_default())
        }
    }
}

// Keep unused imports clean
const _: Option<WorkspaceLayoutState> = None;
const _: Option<PersistedWorkspaceSession> = None;
const _: fn(&[u8], &Path) -> Result<(), String> = write_atomic_0600;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::WorkspaceTarget;

    fn dispatch(handle: *mut TalusManagerHandle, payload: serde_json::Value) -> String {
        let req = CString::new(payload.to_string()).unwrap();
        let ptr = talus_manager_dispatch(handle, req.as_ptr());
        assert!(!ptr.is_null());
        let out = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
        talus_string_free(ptr);
        out
    }

    #[test]
    fn manager_dispatch_decodes_non_empty_live_frames_for_all_ops() {
        let mut cfg = Configuration::default();
        cfg.workspace_mode = "virtual".to_string();
        cfg.workspace_count = 5;
        cfg.app_workspaces
            .insert("com.apple.Terminal".to_string(), WorkspaceTarget::Index(2));
        cfg.app_workspaces.insert(
            "com.google.Chrome".to_string(),
            WorkspaceTarget::Label("网页".to_string()),
        );
        let cfg_c = CString::new(serde_json::to_string(&cfg).unwrap()).unwrap();
        let empty = CString::new("").unwrap();
        let handle = talus_manager_new(cfg_c.as_ptr(), empty.as_ptr());
        assert!(!handle.is_null());

        let refresh_out: ManagerActionOutput = serde_json::from_str(&dispatch(
            handle,
            serde_json::json!({
                "op": "refresh",
                "force": true,
                "now": 100.0,
                "screens": [{
                    "id": 0,
                    "visibleFrame": {"x": 0.0, "y": 34.0, "w": 1710.0, "h": 1073.0},
                    "fullFrame": {"x": 0.0, "y": 0.0, "w": 1710.0, "h": 1107.0}
                }],
                "candidates": [{
                    "key": 1,
                    "pid": 1001,
                    "bundleId": "com.example.App",
                    "windowId": 42,
                    "title": "Main",
                    "screenId": 0,
                    "isResizable": true,
                    "frame": {"x": 0.0, "y": 34.0, "w": 855.0, "h": 1073.0}
                }],
                "busyPids": [],
                "visibleWindowIds": [42],
                "allExistingCgWindowIds": [42],
                "deadHistoryKeys": [],
                "eligibleVisibleWindowExists": true,
                "frontmostKey": 1,
                "traceEvents": false
            }),
        ))
        .unwrap();
        assert_eq!(refresh_out.active_workspace, 0);

        let live_frames = serde_json::json!({
            "1": {"x": 0.0, "y": 34.0, "w": 1710.0, "h": 1073.0}
        });

        let switch_out: ManagerActionOutput = serde_json::from_str(&dispatch(
            handle,
            serde_json::json!({
                "op": "switchWorkspace",
                "index": 1,
                "now": 101.0,
                "trusted": true,
                "frontmostKey": 1,
                "liveFrames": live_frames
            }),
        ))
        .unwrap();
        assert_eq!(switch_out.active_workspace, 1);
        assert!(switch_out.status_changed);
        assert!(!switch_out.effects.is_empty());

        let move_out: ManagerActionOutput = serde_json::from_str(&dispatch(
            handle,
            serde_json::json!({
                "op": "moveWindowToWorkspace",
                "index": 2,
                "now": 102.0,
                "trusted": true,
                "frontmostKey": 1,
                "liveFrames": live_frames
            }),
        ))
        .unwrap();
        assert!(move_out.is_virtual_mode);

        let key_out: ManagerActionOutput = serde_json::from_str(&dispatch(
            handle,
            serde_json::json!({
                "op": "handleKey",
                "code": 49,
                "shift": false,
                "now": 103.0,
                "trusted": true,
                "frontmostKey": 1,
                "liveFrames": live_frames
            }),
        ))
        .unwrap();
        assert_eq!(key_out.layout_name, "Mirror");

        let ax_out: ManagerActionOutput = serde_json::from_str(&dispatch(
            handle,
            serde_json::json!({
                "op": "handleAxFocusNotification",
                "now": 104.0,
                "trusted": true,
                "locked": false,
                "frontmostKey": 1,
                "liveFrames": live_frames
            }),
        ))
        .unwrap();
        assert!(ax_out.is_virtual_mode);

        let app_out: ManagerActionOutput = serde_json::from_str(&dispatch(
            handle,
            serde_json::json!({
                "op": "handleApplicationActivated",
                "pid": 1001,
                "now": 105.0,
                "trusted": true,
                "locked": false,
                "appFocusedKey": 1,
                "liveFrames": live_frames
            }),
        ))
        .unwrap();
        assert!(app_out.is_virtual_mode);

        let cfg_out: ManagerActionOutput = serde_json::from_str(&dispatch(
            handle,
            serde_json::json!({
                "op": "applyConfig",
                "config": cfg,
                "now": 106.0,
                "trusted": true,
                "frontmostKey": 1,
                "liveFrames": live_frames
            }),
        ))
        .unwrap();
        assert_eq!(cfg_out.workspace_count, 5);

        let park_out: ManagerActionOutput = serde_json::from_str(&dispatch(
            handle,
            serde_json::json!({
                "op": "switchWorkspace",
                "index": 3,
                "now": 106.5,
                "trusted": true,
                "frontmostKey": 1,
                "liveFrames": live_frames
            }),
        ))
        .unwrap();
        assert_eq!(park_out.active_workspace, 3);

        let restore_out: ManagerActionOutput = serde_json::from_str(&dispatch(
            handle,
            serde_json::json!({
                "op": "restoreAllParkedWindows",
                "trusted": true,
                "liveFrames": live_frames
            }),
        ))
        .unwrap();
        assert!(!restore_out.effects.is_empty());

        let invalid_out = dispatch(
            handle,
            serde_json::json!({
                "op": "switchWorkspace",
                "index": 1,
                "now": 107.0,
                "trusted": true,
                "frontmostKey": 1,
                "liveFrames": {"not_a_number": {"x": 0.0, "y": 0.0, "w": 100.0, "h": 100.0}}
            }),
        );
        assert_eq!(invalid_out, "{}");

        talus_manager_free(handle);
    }
}
