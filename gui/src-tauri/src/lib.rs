mod sidecar;

use sidecar::SidecarProcess;
use std::sync::Mutex;
use tauri::State;

struct AppState {
    sidecar: Mutex<Option<SidecarProcess>>,
    prosca_dir: String,
}

#[tauri::command]
fn start_sidecar(state: State<AppState>, app_handle: tauri::AppHandle) -> Result<(), String> {
    let mut sidecar_guard = state.sidecar.lock().map_err(|e| e.to_string())?;
    if sidecar_guard.is_some() {
        return Ok(()); // Already running
    }
    let process = SidecarProcess::spawn(&state.prosca_dir, app_handle)?;
    *sidecar_guard = Some(process);
    Ok(())
}

#[tauri::command]
fn send_to_sidecar(state: State<AppState>, message: String) -> Result<(), String> {
    let guard = state.sidecar.lock().map_err(|e| e.to_string())?;
    match &*guard {
        Some(process) => process.send(&message),
        None => Err("Sidecar not running".to_string()),
    }
}

#[tauri::command]
fn stop_sidecar(state: State<AppState>) -> Result<(), String> {
    let mut guard = state.sidecar.lock().map_err(|e| e.to_string())?;
    if let Some(mut process) = guard.take() {
        process.kill();
    }
    Ok(())
}

pub fn run() {
    env_logger::init();

    // Determine Prosca directory — navigate from the executable location.
    // The binary lives at gui/src-tauri/target/*/prosca, so we go up
    // to find the Prosca root. In dev mode, fall back to PROSCA_DIR env var
    // or the parent of the current directory.
    let prosca_dir = std::env::var("PROSCA_DIR").unwrap_or_else(|_| {
        eprintln!("[prosca] current_exe: {:?}", std::env::current_exe());
        eprintln!("[prosca] current_dir: {:?}", std::env::current_dir());
        std::env::current_exe()
            .ok()
            .and_then(|p| {
                // Walk up from executable to find json_io.jl
                let mut dir = p.parent().map(|p| p.to_path_buf());
                for _ in 0..6 {
                    if let Some(ref d) = dir {
                        if d.join("json_io.jl").exists() {
                            return Some(d.to_string_lossy().to_string());
                        }
                        dir = d.parent().map(|p| p.to_path_buf());
                    }
                }
                None
            })
            .unwrap_or_else(|| {
                // Fallback: assume launched from gui/ subdirectory
                std::env::current_dir()
                    .map(|p| p.parent().unwrap_or(&p).to_string_lossy().to_string())
                    .unwrap_or_else(|_| ".".to_string())
            })
    });

    eprintln!("[prosca] resolved prosca_dir: {}", prosca_dir);
    let mut builder = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init());

    #[cfg(debug_assertions)]
    {
        builder = builder.plugin(tauri_plugin_mcp_bridge::init());
    }

    builder
        .manage(AppState {
            sidecar: Mutex::new(None),
            prosca_dir,
        })
        .invoke_handler(tauri::generate_handler![
            start_sidecar,
            send_to_sidecar,
            stop_sidecar,
        ])
        .setup(|_app| {
            // Set the dock icon explicitly for dev mode (no .app bundle)
            #[cfg(target_os = "macos")]
            {
                use objc2::AnyThread;
                use objc2_app_kit::{NSApplication, NSImage};
                use objc2_foundation::{NSData, MainThreadMarker};
                let icon_bytes = include_bytes!("../icons/128x128@2x.png");
                unsafe {
                    let data = NSData::with_bytes(icon_bytes);
                    if let Some(image) = NSImage::initWithData(NSImage::alloc(), &data) {
                        let mtm = MainThreadMarker::new_unchecked();
                        let app = NSApplication::sharedApplication(mtm);
                        app.setApplicationIconImage(Some(&image));
                    }
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
