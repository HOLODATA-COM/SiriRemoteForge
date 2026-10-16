use crate::core::{self, Settings};
use reqwest::{multipart, Client};
use serde_json::{json, Value};
use std::time::Duration;

pub fn credential(provider: &str) -> Result<keyring::Entry, String> {
    if !["openai", "deepseek"].contains(&provider) {
        return Err("未知的 API 服务".into());
    }
    keyring::Entry::new("com.holodata.voiceink", provider).map_err(|_| "系统密钥存储不可用".into())
}
pub fn key(provider: &str) -> Result<String, String> {
    credential(provider)?
        .get_password()
        .map_err(|_| format!("请先在设置中保存 {provider} API Key"))
}
pub fn save_key(provider: &str, value: &str) -> Result<(), String> {
    let value = value.trim();
    if value.is_empty() || value.len() > 4096 || value.chars().any(char::is_whitespace) {
        return Err("API Key 不能为空，也不能包含空格".into());
    }
    credential(provider)?
        .set_password(value)
        .map_err(|_| "无法保存到系统密钥存储".into())
}
pub fn client() -> Result<Client, String> {
    Client::builder()
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(35))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "无法初始化网络连接".into())
}
async fn response(request: reqwest::RequestBuilder) -> Result<Value, String> {
    let r = request.send().await.map_err(|e| {
        if e.is_timeout() {
            "服务响应超时，可重试这段录音"
        } else {
            "无法连接服务，请检查网络"
        }
    })?;
    let status = r.status();
    if !status.is_success() {
        // Provider bodies can contain user text or echoed credentials: never surface them.
        return Err(match status.as_u16() {
            401 | 403 => "API Key 无效或没有模型权限".into(),
            429 => "服务限流或额度不足，请检查 API 账户".into(),
            400 | 404 => "服务不支持该请求或模型，请检查模型名称".into(),
            _ => format!("服务暂时不可用（HTTP {}），录音可重试", status.as_u16()),
        });
    }
    r.json()
        .await
        .map_err(|_| "服务返回了无法读取的数据".into())
}
pub async fn transcribe(client: &Client, wav: Vec<u8>, s: &Settings) -> Result<String, String> {
    let mut form = multipart::Form::new()
        .text("model", s.transcription_model.clone())
        .text("response_format", "json")
        .part(
            "file",
            multipart::Part::bytes(wav)
                .file_name("dictation.wav")
                .mime_str("audio/wav")
                .map_err(|_| "录音格式错误")?,
        );
    if !s.dictionary.is_empty() {
        form = form.text("prompt", s.dictionary.join(", "));
    }
    let value = response(
        client
            .post("https://api.openai.com/v1/audio/transcriptions")
            .bearer_auth(key("openai")?)
            .multipart(form),
    )
    .await?;
    value["text"]
        .as_str()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
        .ok_or("没有识别到文字，请检查麦克风输入".into())
}
pub async fn rewrite(
    client: &Client,
    s: &Settings,
    instructions: &str,
    input: Value,
) -> Result<String, String> {
    let encoded = serde_json::to_string(&input).map_err(|_| "无法生成文字请求")?;
    let request=match s.cleanup_provider.as_str() {
        "openai" => client.post("https://api.openai.com/v1/responses").bearer_auth(key("openai")?)
            .json(&json!({"model":s.cleanup_model,"instructions":instructions,"input":encoded,"store":false})),
        "deepseek" => client.post("https://api.deepseek.com/chat/completions").bearer_auth(key("deepseek")?)
            .json(&json!({"model":s.cleanup_model,"messages":[{"role":"system","content":instructions},{"role":"user","content":encoded}],"stream":false})),
        _ => return Err("请为语音修改选择润色服务".into()),
    };
    let value = response(request).await?;
    core::output_text(&value).ok_or("润色没有返回有效文字".into())
}
pub async fn test_key(provider: &str) -> Result<(), String> {
    let url = match provider {
        "openai" => "https://api.openai.com/v1/models",
        "deepseek" => "https://api.deepseek.com/models",
        _ => return Err("未知服务".into()),
    };
    response(client()?.get(url).bearer_auth(key(provider)?))
        .await
        .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    fn endpoint(status: &str, body: &str) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let reply=format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len());
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0; 8192];
            let _ = stream.read(&mut request);
            stream.write_all(reply.as_bytes()).unwrap();
        });
        url
    }
    #[tokio::test]
    async fn provider_errors_do_not_expose_echoed_secrets_or_transcripts() {
        let url = endpoint(
            "401 Unauthorized",
            r#"{"error":{"message":"SECRET_SENTINEL user transcript"}}"#,
        );
        let error = response(client().unwrap().get(url)).await.unwrap_err();
        assert!(error.contains("API Key"));
        assert!(!error.contains("SECRET_SENTINEL"));
        assert!(!error.contains("transcript"));
    }
    #[tokio::test]
    async fn valid_provider_json_and_invalid_body_are_distinguished() {
        let url = endpoint("200 OK", r#"{"text":"你好"}"#);
        assert_eq!(
            response(client().unwrap().get(url)).await.unwrap()["text"],
            "你好"
        );
        let url = endpoint("200 OK", "not-json");
        assert!(response(client().unwrap().get(url)).await.is_err());
    }
    #[tokio::test]
    async fn redirects_never_forward_authorization_to_another_host() {
        let url = endpoint("302 Found", "{}");
        let error = response(
            client()
                .unwrap()
                .get(url)
                .bearer_auth("TEST-ONLY-NOT-A-SECRET"),
        )
        .await
        .unwrap_err();
        assert!(error.contains("302"));
    }
}
