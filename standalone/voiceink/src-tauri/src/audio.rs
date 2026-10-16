use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::{mpsc, Arc, Mutex};

#[derive(Default)]
pub struct Samples {
    pub data: Vec<f32>,
    pub level: f32,
    pub error: Option<String>,
}
pub struct Recording {
    pub samples: Vec<f32>,
    pub rate: u32,
}
enum Command {
    Start(String, mpsc::Sender<Result<(), String>>),
    Stop(mpsc::Sender<Result<Recording, String>>),
    Cancel,
}
pub struct AudioWorker {
    tx: mpsc::Sender<Command>,
    pub meter: Arc<Mutex<Samples>>,
}
impl AudioWorker {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel();
        let meter = Arc::new(Mutex::new(Samples::default()));
        let shared = meter.clone();
        std::thread::spawn(move || {
            let mut stream: Option<(cpal::Stream, u32)> = None;
            while let Ok(cmd) = rx.recv() {
                match cmd {
                    Command::Start(device, reply) => {
                        if stream.is_some() {
                            let _ = reply.send(Err("麦克风已在录音".into()));
                            continue;
                        }
                        *shared.lock().unwrap() = Samples::default();
                        match open(&device, shared.clone()) {
                            Ok(value) => {
                                stream = Some(value);
                                let _ = reply.send(Ok(()));
                            }
                            Err(e) => {
                                let _ = reply.send(Err(e));
                            }
                        }
                    }
                    Command::Stop(reply) => {
                        let result = match stream.take() {
                            Some((s, rate)) => {
                                drop(s);
                                let mut values = shared.lock().unwrap();
                                if let Some(error) = values.error.take() {
                                    Err(error)
                                } else {
                                    Ok(Recording {
                                        samples: std::mem::take(&mut values.data),
                                        rate,
                                    })
                                }
                            }
                            None => Err("当前没有录音".into()),
                        };
                        let _ = reply.send(result);
                    }
                    Command::Cancel => {
                        stream = None;
                        *shared.lock().unwrap() = Samples::default();
                    }
                }
            }
        });
        Self { tx, meter }
    }
    pub fn start(&self, device: String) -> Result<(), String> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(Command::Start(device, tx))
            .map_err(|_| "录音线程已退出")?;
        rx.recv().map_err(|_| "录音线程无响应")?
    }
    pub fn stop(&self) -> Result<Recording, String> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(Command::Stop(tx))
            .map_err(|_| "录音线程已退出")?;
        rx.recv().map_err(|_| "录音线程无响应")?
    }
    pub fn cancel(&self) {
        let _ = self.tx.send(Command::Cancel);
    }
}
pub fn devices() -> Result<Vec<String>, String> {
    cpal::default_host()
        .input_devices()
        .map_err(|e| e.to_string())?
        .map(|d| d.name().map_err(|e| e.to_string()))
        .collect()
}
fn open(name: &str, shared: Arc<Mutex<Samples>>) -> Result<(cpal::Stream, u32), String> {
    let host = cpal::default_host();
    let device = if name.is_empty() {
        host.default_input_device()
    } else {
        host.input_devices()
            .ok()
            .and_then(|mut ds| ds.find(|d| d.name().ok().as_deref() == Some(name)))
    }
    .ok_or("找不到麦克风，请检查设备或选择系统默认输入")?;
    let supported = device
        .default_input_config()
        .map_err(|e| format!("无法打开麦克风：{e}"))?;
    let config: cpal::StreamConfig = supported.clone().into();
    let channels = config.channels as usize;
    let rate = config.sample_rate.0;
    let stream = match supported.sample_format() {
        cpal::SampleFormat::F32 => make_stream::<f32>(&device, &config, channels, rate, shared),
        cpal::SampleFormat::I16 => make_stream::<i16>(&device, &config, channels, rate, shared),
        cpal::SampleFormat::U16 => make_stream::<u16>(&device, &config, channels, rate, shared),
        other => return Err(format!("暂不支持麦克风格式 {other:?}")),
    }
    .map_err(|e| format!("麦克风启动失败（请检查麦克风权限）：{e}"))?;
    stream.play().map_err(|e| e.to_string())?;
    Ok((stream, rate))
}
fn make_stream<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    channels: usize,
    rate: u32,
    shared: Arc<Mutex<Samples>>,
) -> Result<cpal::Stream, cpal::BuildStreamError>
where
    T: cpal::SizedSample,
    f32: cpal::FromSample<T>,
{
    let errors = shared.clone();
    device.build_input_stream(
        config,
        move |input: &[T], _| {
            use cpal::Sample;
            let Ok(mut values) = shared.lock() else {
                return;
            };
            let mut energy = 0f32;
            let mut count = 0usize;
            for frame in input.chunks_exact(channels) {
                let mono =
                    frame.iter().map(|v| f32::from_sample(*v)).sum::<f32>() / channels as f32;
                let mono = if mono.is_finite() {
                    mono.clamp(-1., 1.)
                } else {
                    0.
                };
                if values.data.len() < rate as usize * 120 {
                    values.data.push(mono);
                }
                energy += mono * mono;
                count += 1;
            }
            let rms = (energy / count.max(1) as f32).sqrt();
            values.level = (rms * 14.).powf(0.7).clamp(0., 1.);
        },
        move |e| {
            errors.lock().unwrap().error = Some(format!("麦克风连接中断：{e}"));
        },
        None,
    )
}
