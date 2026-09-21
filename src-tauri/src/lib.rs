use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::process::Command;
use std::time::Duration;

use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

const RELAY_ADDR: &str = "127.0.0.1:17321";
const RELAY_UI: &str = "http://127.0.0.1:17321/";
const RELAY_UNIT: &str = "vidyut-relay.service";

#[tauri::command]
fn start_relay(app: AppHandle) -> Result<(), String> {
    ensure_relay()?;
    navigate_to_ui(&app);
    Ok(())
}

#[tauri::command]
fn stop_relay() -> Result<(), String> {
    systemctl("stop")?;
    Ok(())
}

#[tauri::command]
fn pick_and_send_files(app: AppHandle) -> Result<usize, String> {
    send_files_from_dialog(&app)
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            start_relay,
            stop_relay,
            pick_and_send_files
        ])
        .setup(|app| {
            setup_tray(app.handle())?;
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                if ensure_relay().is_ok() {
                    navigate_to_ui(&handle);
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building the Vidyut desktop shell")
        .run(|_app, event| {
            if let tauri::RunEvent::ExitRequested { api, code, .. } = event {
                if code.is_none() {
                    api.prevent_exit();
                }
            }
        });
}

fn setup_tray(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let show = MenuItem::with_id(app, "show", "Show", true, None::<&str>)?;
    let send = MenuItem::with_id(app, "send", "Send files", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &send, &quit])?;
    let icon = app
        .default_window_icon()
        .cloned()
        .ok_or("desktop shell is missing a window icon")?;

    TrayIconBuilder::new()
        .icon(icon)
        .tooltip("Vidyut")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => show_window(app),
            "send" => {
                let _ = send_files_from_dialog(app);
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .build(app)?;
    Ok(())
}

fn show_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn navigate_to_ui(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        if let Ok(url) = RELAY_UI.parse() {
            let _ = window.navigate(url);
        }
    }
}

fn send_files_from_dialog(app: &AppHandle) -> Result<usize, String> {
    use tauri_plugin_dialog::DialogExt;

    let picked = app.dialog().file().blocking_pick_files();
    let Some(files) = picked else {
        return Ok(0);
    };
    let mut paths = Vec::new();
    for file in files {
        match file.into_path() {
            Ok(path) if path.is_file() => paths.push(path.to_string_lossy().into_owned()),
            _ => {}
        }
    }
    if paths.is_empty() {
        return Ok(0);
    }
    ensure_relay()?;
    enqueue_paths(&paths)?;
    Ok(paths.len())
}

fn ensure_relay() -> Result<(), String> {
    if relay_is_up() {
        return Ok(());
    }
    systemctl("start")?;
    for _ in 0..40 {
        if relay_is_up() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    Err("The Relay did not answer on 127.0.0.1:17321.".into())
}

fn systemctl(action: &str) -> Result<(), String> {
    let status = Command::new("systemctl")
        .args(["--user", action, RELAY_UNIT])
        .status()
        .map_err(|error| error.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "systemctl --user {action} {RELAY_UNIT} failed with {status}"
        ))
    }
}

fn relay_is_up() -> bool {
    http_exchange("GET", "/health", None)
        .ok()
        .is_some_and(|body| body.starts_with("HTTP/1.1 200") || body.starts_with("HTTP/1.0 200"))
}

fn enqueue_paths(paths: &[String]) -> Result<(), String> {
    let body = serde_json::json!({ "paths": paths }).to_string();
    let response = http_exchange(
        "POST",
        "/control/v1/transfers/enqueue",
        Some(body.as_bytes()),
    )?;
    if response.contains("HTTP/1.1 202") || response.contains("HTTP/1.0 202") {
        return Ok(());
    }
    if response.contains("HTTP/1.1 200") || response.contains("HTTP/1.0 200") {
        return Ok(());
    }
    Err("The Relay did not accept that batch.".into())
}

fn http_exchange(method: &str, path: &str, body: Option<&[u8]>) -> Result<String, String> {
    let addr = resolve_relay_addr()?;
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(800))
        .map_err(|error| error.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(8)))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(8)))
        .map_err(|error| error.to_string())?;

    let length = body.map(|bytes| bytes.len()).unwrap_or(0);
    let header = format!(
        "{method} {path} HTTP/1.1\r\nHost: {RELAY_ADDR}\r\nContent-Type: application/json\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
    );
    stream
        .write_all(header.as_bytes())
        .map_err(|error| error.to_string())?;
    if let Some(bytes) = body {
        stream
            .write_all(bytes)
            .map_err(|error| error.to_string())?;
    }

    let mut buf = Vec::new();
    stream
        .read_to_end(&mut buf)
        .map_err(|error| error.to_string())?;
    String::from_utf8(buf).map_err(|error| error.to_string())
}

fn resolve_relay_addr() -> Result<SocketAddr, String> {
    RELAY_ADDR
        .to_socket_addrs()
        .map_err(|error| error.to_string())?
        .next()
        .ok_or_else(|| "127.0.0.1:17321 did not resolve".into())
}
