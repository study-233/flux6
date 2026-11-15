use super::*;
use tauri::{http::HeaderValue, webview::NewWindowResponse, WebviewWindowBuilder};

pub(super) fn run() {
    let mut context = tauri::generate_context!();
    let config = context.config_mut();
    config.identifier = "dev.flux6.windows.offline-preview".into();
    let mut window_config = config.app.windows.remove(0);
    window_config.title = "Flux6 · 离线预览".into();
    window_config.visible = true;

    tauri::Builder::default()
        .setup(move |app| {
            WebviewWindowBuilder::from_config(app, &window_config)?
                .incognito(true)
                .center()
                .initialization_script(include_str!("preview.js"))
                .on_navigation(|url| url.host_str() == Some("tauri.localhost"))
                .on_new_window(|_, _| NewWindowResponse::Deny)
                .on_web_resource_request(|_, response| {
                    response.headers_mut().insert("Content-Security-Policy", HeaderValue::from_static(
                        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' ipc: http://ipc.localhost; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"
                    ));
                })
                .build()?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            window_minimize, window_toggle_maximize, window_maximized, window_close,
            window_start_dragging, window_show, app_quit, app_icon_set, set_background
        ])
        .run(context)
        .expect("failed to run offline preview");
}
