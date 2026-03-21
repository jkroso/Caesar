use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use tauri::{AppHandle, Emitter};

const PROSCA_PREFIX: &str = "PROSCA:";

pub struct SidecarProcess {
    child: Child,
    stdin_writer: Arc<Mutex<Option<std::process::ChildStdin>>>,
}

impl SidecarProcess {
    pub fn spawn(prosca_dir: &str, app_handle: AppHandle) -> Result<Self, String> {
        let mut child = Command::new("julia")
            .args(["--project=.", "json_io.jl"])
            .current_dir(prosca_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to spawn Julia: {}", e))?;

        let stdout = child.stdout.take().ok_or("No stdout")?;
        let stderr = child.stderr.take().ok_or("No stderr")?;
        let stdin = child.stdin.take().ok_or("No stdin")?;
        let stdin_writer = Arc::new(Mutex::new(Some(stdin)));

        // Stdout reader — filter for PROSCA: prefix, emit to frontend
        let handle = app_handle.clone();
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                match line {
                    Ok(line) => {
                        if let Some(json_str) = line.strip_prefix(PROSCA_PREFIX) {
                            let _ = handle.emit("sidecar-message", json_str);
                        }
                        // Non-prefixed lines (Julia noise) are ignored
                    }
                    Err(_) => break,
                }
            }
            let _ = handle.emit("sidecar-exit", "process exited");
        });

        // Stderr reader — log but don't forward
        thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines() {
                if let Ok(line) = line {
                    eprintln!("[prosca stderr] {}", line);
                }
            }
        });

        Ok(SidecarProcess {
            child,
            stdin_writer,
        })
    }

    pub fn send(&self, json: &str) -> Result<(), String> {
        let mut guard = self.stdin_writer.lock().map_err(|e| e.to_string())?;
        if let Some(ref mut stdin) = *guard {
            writeln!(stdin, "{}", json).map_err(|e| format!("Write failed: {}", e))?;
            stdin.flush().map_err(|e| format!("Flush failed: {}", e))?;
            Ok(())
        } else {
            Err("Stdin closed".to_string())
        }
    }

    pub fn kill(&mut self) {
        // Close stdin to signal graceful shutdown
        let mut guard = self.stdin_writer.lock().unwrap();
        *guard = None;
        drop(guard);
        let _ = self.child.kill();
    }
}

impl Drop for SidecarProcess {
    fn drop(&mut self) {
        self.kill();
    }
}
