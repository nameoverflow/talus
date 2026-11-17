#ifndef TALUS_CORE_H
#define TALUS_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double x;
    double y;
    double w;
    double h;
} CTalusRect;

typedef struct TalusStatusCommandsHandle TalusStatusCommandsHandle;
typedef struct TalusManagerHandle TalusManagerHandle;

void talus_string_free(char *ptr);

// Layout & Screen Geometry
CTalusRect talus_inset_area(CTalusRect area, double outer_gap);

size_t talus_tall_layout(
    CTalusRect area,
    size_t count,
    size_t masters,
    double ratio,
    CTalusRect *out_rects
);

size_t talus_tall_layout_with_gaps(
    CTalusRect area,
    size_t count,
    size_t masters,
    double ratio,
    double outer_gap,
    double inner_gap,
    CTalusRect *out_rects
);

size_t talus_mirror_tall_layout(
    CTalusRect area,
    size_t count,
    size_t masters,
    double ratio,
    CTalusRect *out_rects
);

size_t talus_mirror_tall_layout_with_gaps(
    CTalusRect area,
    size_t count,
    size_t masters,
    double ratio,
    double outer_gap,
    double inner_gap,
    CTalusRect *out_rects
);

CTalusRect talus_accessibility_frame(CTalusRect visible, double primary_top);

void talus_parked_window_origin(
    double window_w,
    double window_h,
    CTalusRect screen,
    const CTalusRect *all_screens_ptr,
    size_t all_screens_len,
    double *out_x,
    double *out_y
);

bool talus_is_parked_window_frame(CTalusRect frame, CTalusRect screen);

bool talus_matches_visible_window(
    int32_t pid,
    bool has_ax_wid,
    uint32_t ax_wid,
    CTalusRect ax_frame,
    const char *candidates_json
);

bool talus_is_session_locked(
    bool has_screen_locked,
    bool screen_locked,
    bool has_on_console,
    bool on_console,
    const char *frontmost_bundle_id
);

// TOML & Configuration
char *talus_toml_parse_json(const char *source, char **out_error);
char *talus_config_decode_toml_json(const char *source, char **out_error);
bool talus_config_validate_json(const char *config_json, char **out_error);
char *talus_config_to_toml(const char *config_json, const char *existing_toml, char **out_error);
char *talus_config_load_path_json(const char *path, char **out_error);
bool talus_config_save_path_json(const char *config_json, const char *path, char **out_error);
bool talus_float_rule_matches(const char *rule_json, const char *bundle_id, const char *window_title);
char *talus_resolve_paths_json(const char *home_dir, const char *talus_config_env, const char *existing_paths_json);

// Status Text, Markup & Export
bool talus_write_atomic_0600(const uint8_t *bytes, size_t len, const char *path, char **out_error);
char *talus_read_custom_status(const char *path);
char *talus_render_status_json(const char *format, const char *values_json);
char *talus_parse_status_markup_json(const char *request_json);
char *talus_template_status_parts_json(const char *request_json);

// StatusCommandsEngine
TalusStatusCommandsHandle *talus_status_commands_new(
    const char *state_file,
    void (*on_change)(void *),
    void *ctx
);
void talus_status_commands_free(TalusStatusCommandsHandle *handle);
void talus_status_commands_set_state_json(TalusStatusCommandsHandle *handle, const char *state_json);
char *talus_status_commands_get_state_json(TalusStatusCommandsHandle *handle);
char *talus_status_commands_value(TalusStatusCommandsHandle *handle, size_t index, const char *command_json);
void talus_status_commands_state_changed(TalusStatusCommandsHandle *handle, const char *commands_json);
bool talus_status_commands_is_running(TalusStatusCommandsHandle *handle, size_t index);
void talus_status_commands_stop_all(TalusStatusCommandsHandle *handle);

// ManagerCore
TalusManagerHandle *talus_manager_new(const char *config_json, const char *session_file_path);
void talus_manager_free(TalusManagerHandle *handle);
char *talus_manager_dispatch(TalusManagerHandle *handle, const char *request_json);

#ifdef __cplusplus
}
#endif

#endif // TALUS_CORE_H
