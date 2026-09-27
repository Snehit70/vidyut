use std::env;
use std::fs;
use std::sync::OnceLock;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::webview::WebviewWindowBuilder;
use tauri::{AppHandle, Manager, WebviewUrl};

const DEFAULT_RELAY_PORT: u16 = 17321;
const RELAY_UNIT: &str = "vidyut-relay.service";
const TRAY_ID: &str = "vidyut-tray";
const HEALTH_POLL_MS: u64 = 4_000;

// Tray marks, pre-tinted from src-tauri/icons/icon.png with the state colours in
// design/tokens.css. The tray is the only surface left visible all day, so it
// has to say whether the Relay is alive without being clicked.
const ICON_READY: &[u8] = include_bytes!("../icons/tray/ready.png");
const ICON_ATTENTION: &[u8] = include_bytes!("../icons/tray/attention.png");
const ICON_DOWN: &[u8] = include_bytes!("../icons/tray/down.png");
const ICON_STOPPED: &[u8] = include_bytes!("../icons/tray/stopped.png");

/// The disabled first menu row, kept so the health watch can relabel it.
static STATUS_ITEM: OnceLock<MenuItem<tauri::Wry>> = OnceLock::new();

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Health {
    Ready,
    Attention,
    Down,
    Stopped,
}

impl Health {
    fn icon(self) -> &'static [u8] {
        match self {
            Health::Ready => ICON_READY,
            Health::Attention => ICON_ATTENTION,
            Health::Down => ICON_DOWN,
            Health::Stopped => ICON_STOPPED,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Health::Ready => "Ready",
            Health::Attention => "Sync needs attention",
            Health::Down => "Relay down",
            Health::Stopped => "Relay stopped",
        }
    }
}

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

#[tauri::command]
fn open_releases() -> Result<(), String> {
    Command::new("xdg-open")
        .arg("https://github.com/Snehit70/vidyut/releases")
        .spawn()
        .map_err(|error| error.to_string())?;
    Ok(())
}

#[tauri::command]
fn relay_ui() -> String {
    relay_ui_url()
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            start_relay,
            stop_relay,
            pick_and_send_files,
            open_releases,
            relay_ui
        ])
        .setup(|app| {
            setup_window(app.handle())?;
            setup_tray(app.handle())?;
            spawn_health_watch(app.handle());
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

/// The window is built here rather than in tauri.conf.json so it can carry a
/// navigation allow-list.
///
/// The window starts on the bundled page and then navigates to the Relay's
/// loopback control plane. Because that origin is plain HTTP on localhost, any
/// process that answers on the port would be handed the shell's Tauri commands
/// (start_relay shells out to systemctl, pick_and_send_files takes arbitrary
/// paths). Allowing exactly one origin closes that off: the window can reach
/// the configured Relay and nothing else, and a stray link cannot walk it away.
fn setup_window(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let relay_origin = format!("http://127.0.0.1:{}", configured_relay_port());
    let allowed = relay_origin.clone();
    WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .title("Vidyut")
        .inner_size(900.0, 620.0)
        .min_inner_size(560.0, 440.0)
        .center()
        .visible(true)
        .on_navigation(move |url| {
            let href = url.as_str();
            href.starts_with("tauri://localhost")
                || href == allowed
                || href.starts_with(&format!("{allowed}/"))
        })
        .build()?;
    Ok(())
}

fn setup_tray(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let status = MenuItem::with_id(app, "status", "Checking…", false, None::<&str>)?;
    let show = MenuItem::with_id(app, "show", "Show Vidyut", true, None::<&str>)?;
    let send = MenuItem::with_id(app, "send", "Send files", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let _ = STATUS_ITEM.set(status.clone());
    let menu = Menu::with_items(app, &[&status, &show, &send, &quit])?;
    let icon = Image::from_bytes(Health::Attention.icon())
        .map_err(|error| format!("tray icon is unreadable: {error}"))?;

    TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon)
        .tooltip("Vidyut — checking the Relay")
        .menu(&menu)
        // Right click opens the menu; left click is the gesture people expect
        // to bring a window back, so it must not be swallowed by the menu.
        .show_menu_on_left_click(false)
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
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button,
                button_state,
                ..
            } = event
            {
                if button == MouseButton::Left && button_state == MouseButtonState::Up {
                    show_window(tray.app_handle());
                }
            }
        })
        .build(app)?;
    Ok(())
}

/// Polls the Relay and keeps the tray honest. Hiding the window to the tray is
/// the shell's normal state, so this is where health has to be legible: the
/// window is usually closed.
fn spawn_health_watch(app: &AppHandle) {
    let handle = app.clone();
    std::thread::spawn(move || {
        let mut last: Option<(Health, usize)> = None;
        loop {
            let current = read_health();
            if last != Some(current) {
                last = Some(current);
                apply_tray_status(&handle, current.0, current.1);
            }
            std::thread::sleep(Duration::from_millis(HEALTH_POLL_MS));
        }
    });
}

fn read_health() -> (Health, usize) {
    if !relay_is_up() {
        // Distinguish "the user stopped it" from "it is not answering": they
        // need different actions, and a stopped unit is not a fault.
        return if relay_unit_is_active() {
            (Health::Down, 0)
        } else {
            (Health::Stopped, 0)
        };
    }
    let Ok(response) = http_exchange("GET", "/control/v1/state", None) else {
        return (Health::Down, 0);
    };
    let Some(body) = response_body(&response) else {
        return (Health::Down, 0);
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(body) else {
        return (Health::Down, 0);
    };
    let devices = value
        .get("authenticatedDeviceCount")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0) as usize;
    let health = match value.get("syncState").and_then(serde_json::Value::as_str) {
        Some("ready") => Health::Ready,
        // Anything the shell does not recognise is reported as needing
        // attention rather than as fine.
        _ => Health::Attention,
    };
    (health, devices)
}

fn relay_unit_is_active() -> bool {
    Command::new("systemctl")
        .args(["--user", "is-active", RELAY_UNIT])
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).trim() == "active")
        .unwrap_or(false)
}

/// Pull the JSON body out of a raw HTTP/1.1 response.
fn response_body(response: &str) -> Option<&str> {
    let (head, body) = response.split_once("\r\n\r\n")?;
    if !head.starts_with("HTTP/1.1 200") && !head.starts_with("HTTP/1.0 200") {
        return None;
    }
    Some(body.trim())
}

fn apply_tray_status(app: &AppHandle, health: Health, devices: usize) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else {
        return;
    };
    if let Ok(icon) = Image::from_bytes(health.icon()) {
        let _ = tray.set_icon(Some(icon));
    }
    let device_word = if devices == 1 { "device" } else { "devices" };
    let _ = tray.set_tooltip(Some(format!(
        "Vidyut — {} · {devices} {device_word} paired",
        health.label()
    )));
    if let Some(item) = STATUS_ITEM.get() {
        let _ = item.set_text(health.label());
    }
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
        if let Ok(url) = relay_ui_url().parse() {
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
    Err(format!(
        "The Relay did not answer on {}.",
        relay_addr()
    ))
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
    let host = relay_addr();
    let header = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
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
    let host = relay_addr();
    host.to_socket_addrs()
        .map_err(|error| error.to_string())?
        .next()
        .ok_or_else(|| format!("{host} did not resolve"))
}

fn relay_ui_url() -> String {
    format!("http://{}/", relay_addr())
}

fn relay_addr() -> String {
    format!("127.0.0.1:{}", configured_relay_port())
}

fn configured_relay_port() -> u16 {
    fs::read_to_string(relay_config_path())
        .map(|text| parse_relay_port(&text))
        .unwrap_or(DEFAULT_RELAY_PORT)
}

fn relay_config_path() -> PathBuf {
    if let Ok(xdg) = env::var("XDG_CONFIG_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("vidyut").join("relay.json");
        }
    }
    let home = env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home)
        .join(".config")
        .join("vidyut")
        .join("relay.json")
}

pub(crate) fn parse_relay_port(json: &str) -> u16 {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(json) else {
        return DEFAULT_RELAY_PORT;
    };
    match value.get("port") {
        Some(serde_json::Value::Number(number)) => number
            .as_u64()
            .and_then(|port| u16::try_from(port).ok())
            .filter(|port| *port > 0)
            .unwrap_or(DEFAULT_RELAY_PORT),
        _ => DEFAULT_RELAY_PORT,
    }
}

#[cfg(test)]
mod tests {
    use super::{parse_relay_port, response_body, DEFAULT_RELAY_PORT};

    #[test]
    fn default_port_when_json_is_junk() {
        assert_eq!(parse_relay_port("nope"), DEFAULT_RELAY_PORT);
    }

    #[test]
    fn reads_configured_port() {
        assert_eq!(
            parse_relay_port(r#"{"pairingSecret":"x","port":18000}"#),
            18000
        );
    }

    #[test]
    fn rejects_out_of_range_port() {
        assert_eq!(
            parse_relay_port(r#"{"port":70000}"#),
            DEFAULT_RELAY_PORT
        );
        assert_eq!(parse_relay_port(r#"{"port":0}"#), DEFAULT_RELAY_PORT);
    }

    #[test]
    fn reads_the_body_of_a_200_response() {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"syncState\":\"ready\"}";
        assert_eq!(response_body(raw), Some("{\"syncState\":\"ready\"}"));
    }

    #[test]
    fn refuses_a_non_200_response() {
        let raw = "HTTP/1.1 404 Not Found\r\n\r\n{\"syncState\":\"ready\"}";
        assert_eq!(response_body(raw), None);
    }

    #[test]
    fn refuses_a_truncated_response() {
        assert_eq!(response_body("HTTP/1.1 200 OK\r\n"), None);
    }
}
