#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod api;
mod audio;
mod core;
mod platform;
mod store;

use core::{HistoryEntry, Settings};
use serde::Serialize;
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::{Emitter, Manager};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Shortcut, ShortcutState};

fn escape_shortcut() -> Shortcut {
    Shortcut::new(None, Code::Escape)
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Status {
    phase: String,
    text: String,
    message: String,
    generation: u64,
}
impl Default for Status {
    fn default() -> Self {
        Self {
            phase: "idle".into(),
            text: String::new(),
            message: String::new(),
            generation: 0,
        }
    }
}
struct Turn {
    target: Arc<platform::Target>,
    settings: Settings,
    started: Instant,
}
struct Inner {
    settings: Settings,
    history: Vec<HistoryEntry>,
    status: Status,
    recording: Option<Turn>,
    job: Option<tauri::async_runtime::JoinHandle<()>>,
    retry: Option<(Arc<audio::Recording>, Arc<platform::Target>, Settings)>,
}
struct Engine {
    inner: Mutex<Inner>,
    audio: Arc<audio::AudioWorker>,
    gate: tokio::sync::Mutex<()>,
    dir: PathBuf,
}
impl Engine {
    async fn cancel(&self, app: &tauri::AppHandle) {
        self.cancel_owned(app, None).await;
    }
    async fn cancel_owned(&self, app: &tauri::AppHandle, expected: Option<u64>) {
        let _gate = self.gate.lock().await;
        let id = {
            let mut i = self.inner.lock().unwrap();
            if expected.is_some_and(|id| {
                id != i.status.generation || !core::is_active_phase(&i.status.phase)
            }) {
                return;
            }
            i.status.generation += 1;
            i.recording = None;
            i.retry = None;
            if let Some(job) = i.job.take() {
                job.abort();
            }
            i.status.generation
        };
        self.audio.cancel();
        self.status(app, id, "idle", "", "已取消");
    }
    fn publish(app: &tauri::AppHandle, mut status: Status) {
        // Escape belongs to VoiceInk only while a turn is active, never while idle.
        let shortcut = escape_shortcut();
        if core::is_active_phase(&status.phase) {
            if !app.global_shortcut().is_registered(shortcut)
                && app.global_shortcut().register(shortcut).is_err()
            {
                status
                    .message
                    .push_str(" · Esc 被其他程序占用，请用取消按钮");
            }
        } else if app.global_shortcut().is_registered(shortcut) {
            let _ = app.global_shortcut().unregister(shortcut);
        }
        let _ = app.emit("voice-status", &status);
        if let Some(orb) = app.get_webview_window("orb") {
            if status.phase == "idle" {
                let _ = orb.hide();
                let _ = orb.emit("orb-visibility", false);
            } else {
                let reposition = status.phase == "listening" || !orb.is_visible().unwrap_or(false);
                let monitor = if reposition {
                    orb.cursor_position()
                        .ok()
                        .and_then(|cursor| {
                            orb.available_monitors().ok()?.into_iter().find(|monitor| {
                                let p = monitor.position();
                                let s = monitor.size();
                                cursor.x >= p.x as f64
                                    && cursor.x < (p.x as f64 + s.width as f64)
                                    && cursor.y >= p.y as f64
                                    && cursor.y < (p.y as f64 + s.height as f64)
                            })
                        })
                        .or_else(|| orb.primary_monitor().ok().flatten())
                } else {
                    None
                };
                if let Some(monitor) = monitor {
                    let size = monitor.size();
                    let pos = monitor.position();
                    let scale = monitor.scale_factor();
                    let _ = orb.set_position(tauri::PhysicalPosition::new(
                        pos.x + size.width as i32 / 2 - (120. * scale) as i32,
                        pos.y + size.height as i32 - (300. * scale) as i32,
                    ));
                }
                let _ = orb.show();
                let _ = orb.emit("orb-visibility", true);
            }
        }
    }
    fn status(
        &self,
        app: &tauri::AppHandle,
        generation: u64,
        phase: &str,
        text: &str,
        message: &str,
    ) {
        let mut inner = self.inner.lock().unwrap();
        if inner.status.generation != generation {
            return;
        }
        inner.status.phase = phase.into();
        inner.status.text = text.into();
        inner.status.message = message.into();
        let snapshot = inner.status.clone();
        drop(inner);
        Self::publish(app, snapshot);
        if phase == "error" {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(Duration::from_secs(4)).await;
                let engine = app.state::<Arc<Engine>>();
                let inner = engine.inner.lock().unwrap();
                if inner.status.generation == generation && inner.status.phase == "error" {
                    if let Some(orb) = app.get_webview_window("orb") {
                        let _ = orb.hide();
                        let _ = orb.emit("orb-visibility", false);
                    }
                }
            });
        }
    }
    async fn toggle(self: Arc<Self>, app: tauri::AppHandle) -> Result<(), String> {
        self.toggle_with_owner(app, None).await
    }
    async fn toggle_with_owner(
        self: Arc<Self>,
        app: tauri::AppHandle,
        expected_recording: Option<u64>,
    ) -> Result<(), String> {
        let _gate = self.gate.lock().await;
        if let Some(expected) = expected_recording {
            let inner = self.inner.lock().unwrap();
            if inner.recording.is_none() || inner.status.generation != expected {
                return Ok(());
            }
        }
        let stopped = self.inner.lock().unwrap().recording.take();
        if let Some(turn) = stopped {
            let audio = self.audio.clone();
            let result = tauri::async_runtime::spawn_blocking(move || audio.stop())
                .await
                .map_err(|_| "录音线程退出")?;
            let id = self.inner.lock().unwrap().status.generation;
            let recording = match result {
                Ok(r) => Arc::new(r),
                Err(e) => {
                    self.status(&app, id, "error", "", &e);
                    return Err(e);
                }
            };
            if recording.samples.len() < recording.rate as usize {
                self.status(&app, id, "idle", "", "录音不足一秒，已取消");
                return Ok(());
            }
            self.inner.lock().unwrap().retry = Some((
                recording.clone(),
                turn.target.clone(),
                turn.settings.clone(),
            ));
            self.process(app, recording, turn.target, turn.settings, id);
            return Ok(());
        }
        if api::key("openai").is_err() {
            return Err("请先在设置中保存 OpenAI API Key".into());
        }
        let settings = self.inner.lock().unwrap().settings.clone();
        let target = Arc::new(platform::capture(settings.selection_editing)?);
        if target.secure {
            return Err("当前是密码框或系统安全输入，请切换到普通输入区域".into());
        }
        let id = {
            let mut inner = self.inner.lock().unwrap();
            if let Some(job) = inner.job.take() {
                job.abort();
            }
            inner.status.generation += 1;
            inner.status.generation
        };
        let audio = self.audio.clone();
        let device = settings.input_device.clone();
        match tauri::async_runtime::spawn_blocking(move || audio.start(device))
            .await
            .map_err(|_| "录音线程退出")?
        {
            Ok(()) => {}
            Err(e) => {
                self.status(&app, id, "error", "", &e);
                return Err(e);
            }
        }
        self.inner.lock().unwrap().recording = Some(Turn {
            target,
            settings,
            started: Instant::now(),
        });
        self.status(
            &app,
            id,
            "listening",
            "",
            "再按一次快捷键结束 · Esc 取消 · 最长 10 分钟",
        );
        Ok(())
    }
    fn process(
        self: &Arc<Self>,
        app: tauri::AppHandle,
        audio: Arc<audio::Recording>,
        target: Arc<platform::Target>,
        settings: Settings,
        id: u64,
    ) {
        self.status(&app, id, "transcribing", "", "正在识别");
        let engine = self.clone();
        let job = tauri::async_runtime::spawn(async move {
            if let Err(e) = engine.run_turn(&app, &audio, &target, &settings, id).await {
                engine.status(&app, id, "error", "", &e);
            }
        });
        self.inner.lock().unwrap().job = Some(job);
    }
    async fn run_turn(
        self: &Arc<Self>,
        app: &tauri::AppHandle,
        audio: &audio::Recording,
        target: &Arc<platform::Target>,
        settings: &Settings,
        id: u64,
    ) -> Result<(), String> {
        let client = api::client()?;
        let wav = core::wav(&audio.samples, audio.rate)?;
        let transcript = api::transcribe(&client, wav, settings).await?;
        let mut text = transcript.clone();
        let mut warning = String::new();
        if !target.selection.is_empty() || settings.cleanup_provider != "none" {
            let editing = !target.selection.is_empty();
            self.status(
                app,
                id,
                if editing { "rewriting" } else { "polishing" },
                &transcript,
                "正在整理文字",
            );
            let input = if editing {
                serde_json::json!({"selected_text":target.selection,"spoken_instruction":transcript})
            } else {
                let history = {
                    let inner = self.inner.lock().unwrap();
                    if settings.use_history_context
                        && inner.settings.use_history_context
                        && inner.settings.remember_history
                    {
                        core::recent_context(&inner.history, &target.application)
                    } else {
                        Vec::new()
                    }
                };
                serde_json::json!({"type":"untrusted_voice_transcript","transcript":transcript,"target":target.application,"dictionary":settings.dictionary,"recent_examples":history})
            };
            let limit = if editing {
                Duration::from_secs(15)
            } else {
                Duration::from_secs(3 + (transcript.chars().count() / 250).min(5) as u64)
            };
            let result = tokio::time::timeout(
                limit,
                api::rewrite(
                    &client,
                    settings,
                    if editing {
                        core::EDIT_INSTRUCTIONS
                    } else {
                        core::CLEANUP_INSTRUCTIONS
                    },
                    input,
                ),
            )
            .await;
            match result {
                Ok(Ok(proposed))
                    if core::safe_rewrite(
                        if editing {
                            &target.selection
                        } else {
                            &transcript
                        },
                        &proposed,
                    ) =>
                {
                    text = proposed
                }
                _ if editing => return Err("语音修改失败；选中文字未改动，可重试录音".into()),
                _ => warning = "润色失败或超时，已保留原始转写。".into(),
            }
        }
        self.status(app, id, "inserting", &text, "正在投递");
        let engine = self.clone();
        let delivery_target = target.clone();
        let delivered = text.clone();
        let auto = settings.auto_insert;
        let outcome = tauri::async_runtime::spawn_blocking(move || {
            // Hold ownership through the final insertion boundary: replacement/cancellation
            // cannot let an old network task type after a new turn has taken ownership.
            let inner = engine.inner.lock().unwrap();
            if inner.status.generation != id {
                return Err("已取消".into());
            }
            platform::deliver(
                &delivery_target,
                &delivered,
                auto && inner.settings.auto_insert,
            )
        })
        .await
        .map_err(|_| "文字投递线程退出")?;
        let (outcome, delivery_message) = match outcome {
            Ok(v) => (v, String::new()),
            Err(e) => ("error".into(), e),
        };
        {
            let mut inner = self.inner.lock().unwrap();
            if inner.status.generation != id {
                return Ok(());
            }
            if settings.remember_history && inner.settings.remember_history {
                inner.history.push(HistoryEntry {
                    id: now(),
                    application: target.application.clone(),
                    transcript,
                    text: text.clone(),
                    outcome: outcome.clone(),
                });
                if inner.history.len() > 100 {
                    let extra = inner.history.len() - 100;
                    inner.history.drain(..extra);
                }
                if store::write(&self.dir.join("history.json"), &inner.history).is_err() {
                    warning.push_str("本地历史保存失败。");
                }
            }
        }
        let message = format!(
            "{warning}{}",
            if delivery_message.is_empty() {
                if outcome == "copied" {
                    "文字已复制，切回目标应用粘贴"
                } else {
                    "已发送到原输入区域，结果保留在剪贴板"
                }
            } else {
                &delivery_message
            }
        );
        self.status(app, id, &outcome, &text, &message);
        let _ = app.emit("history-updated", ());
        let engine = self.clone();
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_secs(4)).await;
            let inner = engine.inner.lock().unwrap();
            if inner.status.generation == id
                && inner.recording.is_none()
                && ["inserted", "replaced", "copied"].contains(&inner.status.phase.as_str())
            {
                let mut snapshot = inner.status.clone();
                snapshot.phase = "idle".into();
                drop(inner);
                Engine::publish(&app, snapshot);
            }
        });
        Ok(())
    }
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    settings: Settings,
    status: Status,
    history: Vec<HistoryEntry>,
    openai_key: bool,
    deepseek_key: bool,
    accessibility: bool,
}
#[tauri::command]
fn snapshot(engine: tauri::State<'_, Arc<Engine>>) -> Snapshot {
    let i = engine.inner.lock().unwrap();
    Snapshot {
        settings: i.settings.clone(),
        status: i.status.clone(),
        history: i.history.clone(),
        openai_key: api::key("openai").is_ok(),
        deepseek_key: api::key("deepseek").is_ok(),
        accessibility: platform::trusted(false),
    }
}
#[tauri::command]
async fn toggle(
    app: tauri::AppHandle,
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<(), String> {
    engine.inner().clone().toggle(app).await
}
#[tauri::command]
async fn cancel(
    app: tauri::AppHandle,
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<(), String> {
    engine.cancel(&app).await;
    Ok(())
}
#[tauri::command]
async fn retry(app: tauri::AppHandle, engine: tauri::State<'_, Arc<Engine>>) -> Result<(), String> {
    let _gate = engine.gate.lock().await;
    let (audio, target, settings, id) = {
        let mut i = engine.inner.lock().unwrap();
        if i.recording.is_some() {
            return Err("请先结束录音".into());
        }
        let Some((a, t, s)) = i.retry.clone() else {
            return Err("没有可重试的录音".into());
        };
        if let Some(job) = i.job.take() {
            job.abort();
        }
        i.status.generation += 1;
        (a, t, s, i.status.generation)
    };
    engine.process(app, audio, target, settings, id);
    Ok(())
}
#[tauri::command]
async fn save_settings(
    app: tauri::AppHandle,
    engine: tauri::State<'_, Arc<Engine>>,
    settings: Settings,
) -> Result<(), String> {
    let _gate = engine.gate.lock().await;
    settings.validate()?;
    let old = {
        let i = engine.inner.lock().unwrap();
        if i.recording.is_some() {
            return Err("录音期间不能更改设置".into());
        }
        i.settings.clone()
    };
    let new_shortcut: tauri_plugin_global_shortcut::Shortcut = settings
        .shortcut
        .parse()
        .map_err(|_| "快捷键格式无效，例如 CommandOrControl+Shift+Space")?;
    if new_shortcut == escape_shortcut() {
        return Err("Esc 专用于取消，请选择其他开始快捷键".into());
    }
    if old.shortcut != settings.shortcut {
        app.global_shortcut()
            .register(new_shortcut)
            .map_err(|_| "快捷键已被占用，请换一个组合")?;
    }
    if let Err(e) = store::write(&engine.dir.join("settings.json"), &settings) {
        if old.shortcut != settings.shortcut {
            let _ = app.global_shortcut().unregister(new_shortcut);
        }
        return Err(e);
    }
    if old.shortcut != settings.shortcut {
        if let Ok(old) = old
            .shortcut
            .parse::<tauri_plugin_global_shortcut::Shortcut>()
        {
            let _ = app.global_shortcut().unregister(old);
        }
    }
    if !settings.remember_history {
        store::write(
            &engine.dir.join("history.json"),
            &Vec::<HistoryEntry>::new(),
        )?;
    }
    let mut i = engine.inner.lock().unwrap();
    if !settings.remember_history {
        i.history.clear();
    }
    i.settings = settings;
    Ok(())
}
#[tauri::command]
fn save_api_key(provider: String, value: String) -> Result<(), String> {
    api::save_key(&provider, &value)
}
#[tauri::command]
fn delete_api_key(provider: String) -> Result<(), String> {
    api::credential(&provider)?
        .delete_credential()
        .or_else(|e| {
            if matches!(e, keyring::Error::NoEntry) {
                Ok(())
            } else {
                Err(e)
            }
        })
        .map_err(|_| "无法删除密钥".into())
}
#[tauri::command]
async fn test_api_key(provider: String) -> Result<(), String> {
    api::test_key(&provider).await
}
#[tauri::command]
fn input_devices() -> Result<Vec<String>, String> {
    audio::devices()
}
#[tauri::command]
fn request_accessibility() -> bool {
    platform::trusted(true)
}
#[tauri::command]
fn copy_text(text: String) -> Result<(), String> {
    platform::copy(&text)
}
#[tauri::command]
fn clear_history(engine: tauri::State<'_, Arc<Engine>>) -> Result<(), String> {
    let mut i = engine.inner.lock().unwrap();
    store::write(
        &engine.dir.join("history.json"),
        &Vec::<HistoryEntry>::new(),
    )?;
    i.history.clear();
    i.retry = None;
    Ok(())
}
#[tauri::command]
fn correct_history(
    engine: tauri::State<'_, Arc<Engine>>,
    id: u64,
    text: String,
) -> Result<(), String> {
    if text.len() > 100_000 {
        return Err("文字过长".into());
    }
    let mut i = engine.inner.lock().unwrap();
    let mut history = i.history.clone();
    let item = history
        .iter_mut()
        .find(|e| e.id == id)
        .ok_or("记录不存在")?;
    item.text = text;
    store::write(&engine.dir.join("history.json"), &history)?;
    i.history = history;
    Ok(())
}
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.set_focus();
                let _ = w.emit("main-visibility", true);
            }
        }))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    if *shortcut == escape_shortcut() {
                        if event.state() == ShortcutState::Pressed {
                            let app = app.clone();
                            let engine = app.state::<Arc<Engine>>().inner().clone();
                            let id = engine.inner.lock().unwrap().status.generation;
                            tauri::async_runtime::spawn(async move {
                                engine.cancel_owned(&app, Some(id)).await;
                            });
                        }
                        return;
                    }
                    // Release commits one clean press and avoids auto-repeat and held modifiers at paste.
                    if event.state() == ShortcutState::Released {
                        let app = app.clone();
                        let engine = app.state::<Arc<Engine>>().inner().clone();
                        tauri::async_runtime::spawn(async move {
                            if let Err(e) = engine.clone().toggle(app.clone()).await {
                                let id = engine.inner.lock().unwrap().status.generation;
                                engine.status(&app, id, "error", "", &e);
                            }
                        });
                    }
                })
                .build(),
        )
        .setup(|app| {
            let dir = app.path().app_config_dir()?;
            let (settings, history) = store::initialize(&dir).map_err(std::io::Error::other)?;
            let engine = Arc::new(Engine {
                inner: Mutex::new(Inner {
                    settings: settings.clone(),
                    history,
                    status: Status::default(),
                    recording: None,
                    job: None,
                    retry: None,
                }),
                audio: Arc::new(audio::AudioWorker::new()),
                gate: tokio::sync::Mutex::new(()),
                dir,
            });
            app.manage(engine.clone());
            if app
                .global_shortcut()
                .register(settings.shortcut.as_str())
                .is_err()
            {
                engine.status(
                    app.handle(),
                    0,
                    "error",
                    "",
                    "快捷键注册失败，请在设置中更换组合",
                );
            }
            if let Some(orb) = app.get_webview_window("orb") {
                let _ = orb.set_ignore_cursor_events(true);
            }
            let show =
                tauri::menu::MenuItem::with_id(app, "show", "VoiceInk 设置", true, None::<&str>)?;
            let cancel =
                tauri::menu::MenuItem::with_id(app, "cancel", "取消本次语音", true, None::<&str>)?;
            let quit =
                tauri::menu::MenuItem::with_id(app, "quit", "退出 VoiceInk", true, None::<&str>)?;
            let menu = tauri::menu::Menu::with_items(app, &[&show, &cancel, &quit])?;
            let icon = app.default_window_icon().cloned().ok_or("缺少应用图标")?;
            tauri::tray::TrayIconBuilder::new()
                .icon(icon)
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                            let _ = w.emit("main-visibility", true);
                        }
                    }
                    "cancel" => {
                        let e = app.state::<Arc<Engine>>().inner().clone();
                        let app = app.clone();
                        tauri::async_runtime::spawn(async move {
                            e.cancel(&app).await;
                        });
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let mut ticker = tokio::time::interval(Duration::from_millis(45));
                loop {
                    ticker.tick().await;
                    let capture = {
                        let inner = engine.inner.lock().unwrap();
                        inner
                            .recording
                            .as_ref()
                            .map(|t| (t.started.elapsed(), inner.status.generation))
                    };
                    if let Some((elapsed, generation)) = capture {
                        let (level, error) = {
                            let m = engine.audio.meter.lock().unwrap();
                            (m.level, m.error.clone())
                        };
                        let _ = handle.emit(
                            "voice-meter",
                            serde_json::json!({"level":level,"elapsed":elapsed.as_secs_f32()}),
                        );
                        if elapsed >= Duration::from_secs(core::MAX_RECORDING_SECONDS)
                            || error.is_some()
                        {
                            // A delayed maximum-duration/device-error tick may only stop the
                            // recording it observed, never start or stop a replacement turn.
                            let _ = engine
                                .clone()
                                .toggle_with_owner(handle.clone(), Some(generation))
                                .await;
                        }
                    }
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "main" {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = window.hide();
                    let _ = window.emit("main-visibility", false);
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            snapshot,
            toggle,
            cancel,
            retry,
            save_settings,
            save_api_key,
            delete_api_key,
            test_api_key,
            input_devices,
            request_accessibility,
            copy_text,
            clear_history,
            correct_history
        ])
        .run(tauri::generate_context!())
        .expect("VoiceInk could not initialize");
}
