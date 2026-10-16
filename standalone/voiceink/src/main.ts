import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Orb } from "./orb";
import "./style.css";

type Settings = {
  shortcut: string;
  transcriptionModel: string;
  cleanupProvider: string;
  cleanupModel: string;
  dictionary: string[];
  autoInsert: boolean;
  rememberHistory: boolean;
  useHistoryContext: boolean;
  selectionEditing: boolean;
  inputDevice: string;
};
type Status = {
  phase: string;
  text: string;
  message: string;
  generation: number;
};
type Entry = {
  id: number;
  application: string;
  transcript: string;
  text: string;
  outcome: string;
};
type Snapshot = {
  settings: Settings;
  status: Status;
  history: Entry[];
  openaiKey: boolean;
  deepseekKey: boolean;
  accessibility: boolean;
};
const preview = !(window as unknown as { __TAURI_INTERNALS__?: unknown })
  .__TAURI_INTERNALS__;
const labels: Record<string, string> = {
  idle: "Ready",
  listening: "Listening",
  transcribing: "Transcribing",
  polishing: "Polishing",
  rewriting: "Rewriting",
  inserting: "Inserting",
  inserted: "Done",
  replaced: "Done",
  copied: "Copied",
  error: "Oops",
};
let current: Status = { phase: "idle", text: "", message: "", generation: 0 };
let settings: Settings;
let mainVisible = true,
  activePage = "voice";
const root = document.querySelector<HTMLDivElement>("#app")!;
const isOrb = new URLSearchParams(location.search).has("orb");
const $ = <T extends HTMLElement = HTMLElement>(selector: string) =>
  document.querySelector<T>(selector)!;
async function call<T = void>(
  command: string,
  args?: Record<string, unknown>,
): Promise<T> {
  if (preview)
    throw new Error("网页为界面预览；录音和密钥设置请使用桌面 App。");
  return invoke<T>(command, args);
}
function notify(message: unknown) {
  const text = message instanceof Error ? message.message : String(message);
  if (isOrb) {
    $("#phase").textContent = text;
    return;
  }
  $("#notice").textContent = text;
  $("#notice").hidden = false;
}
async function action(command: string, args?: Record<string, unknown>) {
  try {
    await call(command, args);
  } catch (e) {
    notify(e);
  }
}
if (isOrb) {
  document.body.className = "orb-window";
  root.innerHTML = `<div class="orb-frost"></div><canvas id="orb" aria-hidden="true"></canvas><span id="phase" role="status">Ready</span>`;
} else {
  root.innerHTML = `
  <aside><div class="brand"><span class="brand-mark">v<span>i</span></span> VoiceInk <small>0.1</small></div>
  <p class="brand-note">Your voice,<br>beautifully written.</p>
  <nav aria-label="主要导航"><button class="nav active" data-page="voice">◌ <span>语音输入</span></button><button class="nav" data-page="settings">⚙ <span>设置与密钥</span></button><button class="nav" data-page="history">↺ <span>本地历史</span></button></nav>
  <div class="aside-footer"><span class="privacy-dot"></span> 自带 Key · 无账号<br><small>开源 / GPL-3.0-or-later</small></div></aside>
  <main><div id="notice" role="alert" hidden></div>
  <section id="page-voice" class="page"><header><span class="eyebrow">A LITTLE SPACE FOR YOUR VOICE</span><h1>说出来，就写好了。</h1><p>在任何输入框，用你的声音自然地表达。</p></header>
  <div class="voice-stage"><canvas id="orb" aria-hidden="true"></canvas><span id="phase" role="status">Ready</span><p id="message">按一下开始，再按一下结束。</p><div class="voice-buttons"><button id="toggle" class="primary">开始录音</button><button id="cancel" class="quiet" hidden>取消</button></div><kbd id="shortcut-display">⌘ / Ctrl + Shift + Space</kbd><p class="hint">切回目标输入框，用快捷键启动；点击这里录音时，结果会留在剪贴板。</p></div>
  <div class="result-card"><div class="card-title"><h2>最近一次结果</h2><div><button id="retry" class="text-button">重试录音</button><button id="copy" class="text-button">复制</button></div></div><textarea id="result" placeholder="你的话会出现在这里。" aria-label="转写结果"></textarea></div>
  <footer>录音只在主动触发时开始。关闭窗口后，VoiceInk 会留在托盘中。</footer></section>
  <section id="page-settings" class="page" hidden><header><span class="eyebrow">MAKE IT YOURS</span><h1>轻一点，顺手一点。</h1><p>Key 安全保存在系统密钥存储中，不会写入配置文件。</p></header>
  <div class="settings-card"><h2>服务密钥</h2><label>OpenAI <span id="openai-state" class="tag">未设置</span><div class="input-row"><input id="openai-key" type="password" autocomplete="off" placeholder="粘贴你的 OpenAI API Key" spellcheck="false"><button data-save-key="openai">保存</button><button data-test-key="openai">测试</button><button data-delete-key="openai" class="text-button">删除</button></div></label>
  <label>DeepSeek <span id="deepseek-state" class="tag">可选</span><div class="input-row"><input id="deepseek-key" type="password" autocomplete="off" placeholder="使用 DeepSeek 润色时填写" spellcheck="false"><button data-save-key="deepseek">保存</button><button data-test-key="deepseek">测试</button><button data-delete-key="deepseek" class="text-button">删除</button></div></label><p class="hint">音频发送至 OpenAI；润色文字发送至所选服务，费用由服务商计入你的 API 账户。密钥测试只验证连接和认证，模型权限以实际请求为准。</p></div>
  <form id="settings-form"><div class="settings-card"><h2>输入与转写</h2><label>全局快捷键<input id="shortcut" placeholder="CommandOrControl+Shift+Space" required></label><p class="hint">按一下开始，再按一下停止。使用修饰键加普通键的组合，例如 CommandOrControl+Shift+Space。</p><label>麦克风<select id="input-device"><option value="">系统默认输入</option></select></label><label>转写模型<input id="transcription-model" required></label><div class="field-grid"><label>润色服务<select id="cleanup-provider"><option value="none">不润色</option><option value="deepseek">DeepSeek</option><option value="openai">OpenAI</option></select></label><label>润色模型<input id="cleanup-model"></label></div><label class="check"><input type="checkbox" id="auto-insert">自动插入原输入区域（焦点变化时仅复制）</label><label class="check"><input type="checkbox" id="selection-editing">选中文字时，按语音指令修改（需要润色服务）</label><div class="permission-row"><span id="permission">辅助功能权限</span><button type="button" id="permissions">检查 / 授权</button></div></div>
  <div class="settings-card"><h2>个人词典</h2><p class="hint">每行一个词。作为转写和润色的提示，不做不确定的强制替换。</p><textarea id="dictionary" rows="4" aria-label="个人词典"></textarea></div>
  <div class="settings-card"><h2>历史与隐私</h2><label class="check"><input type="checkbox" id="remember-history">在本机保存最近 100 条文字记录</label><label class="check"><input type="checkbox" id="use-history-context">将同一应用最近 20 条记录作为润色上下文发送</label><p class="hint">默认关闭历史。开启上下文后，相关历史文字也会发送至润色服务。音频仅留在内存中供重试，退出 App 即清除。历史中的手动修正会用于后续上下文。</p></div><button class="primary" type="submit">保存设置</button></form></section>
  <section id="page-history" class="page" hidden><header><span class="eyebrow">WORDS WORTH KEEPING</span><h1>写过，也能再修正。</h1><p>这里的修改会成为以后更准确的上下文。</p></header><div class="card-title"><h2>最近记录</h2><button id="clear-history" class="text-button">清空历史与重试录音</button></div><div id="history-list"></div></section></main>`;
}
const orb = new Orb($("#orb"));
if (isOrb) orb.setVisible(false);
function status(next: Status) {
  if (next.generation < current.generation) return;
  current = next;
  orb.setPhase(next.phase);
  $("#phase").textContent = labels[next.phase] || next.phase;
  document.body.dataset.phase = next.phase;
  if (isOrb) {
    orb.setVisible(next.phase !== "idle");
    return;
  }
  const active = [
    "listening",
    "transcribing",
    "polishing",
    "rewriting",
    "inserting",
  ].includes(next.phase);
  $("#toggle").textContent =
    next.phase === "listening"
      ? "结束录音"
      : active
        ? "取消上次，开始新录音"
        : "开始录音";
  $("#cancel").hidden = !active;
  $("#message").textContent = next.message || "按一下开始，再按一下结束。";
  if (next.text) $<HTMLTextAreaElement>("#result").value = next.text;
}
function applySettings(s: Settings) {
  settings = s;
  $("#shortcut-display").textContent = s.shortcut;
  $("#shortcut").setAttribute("value", s.shortcut);
  $<HTMLInputElement>("#shortcut").value = s.shortcut;
  $<HTMLInputElement>("#transcription-model").value = s.transcriptionModel;
  $<HTMLInputElement>("#cleanup-model").value = s.cleanupModel;
  $<HTMLSelectElement>("#cleanup-provider").value = s.cleanupProvider;
  $<HTMLSelectElement>("#input-device").value = s.inputDevice;
  $<HTMLTextAreaElement>("#dictionary").value = s.dictionary.join("\n");
  for (const [id, value] of [
    ["auto-insert", s.autoInsert],
    ["selection-editing", s.selectionEditing],
    ["remember-history", s.rememberHistory],
    ["use-history-context", s.useHistoryContext],
  ] as const)
    $<HTMLInputElement>(`#${id}`).checked = value;
}
function history(items: Entry[]) {
  const list = $("#history-list");
  list.replaceChildren();
  if (!items.length) {
    const p = document.createElement("p");
    p.className = "empty";
    p.textContent = "还没有本地历史。你可以在设置里选择开启。";
    list.append(p);
    return;
  }
  for (const item of [...items].reverse()) {
    const card = document.createElement("article");
    card.className = "history-card";
    const title = document.createElement("div");
    title.className = "history-meta";
    title.textContent = `${new Date(item.id).toLocaleString()} · ${item.application} · ${item.outcome}`;
    const text = document.createElement("textarea");
    text.value = item.text;
    text.setAttribute("aria-label", "修正历史文字");
    const save = document.createElement("button");
    save.textContent = "保存修正";
    save.onclick = () =>
      action("correct_history", { id: item.id, text: text.value });
    const copy = document.createElement("button");
    copy.textContent = "复制";
    copy.onclick = () => action("copy_text", { text: text.value });
    card.append(title, text, save, copy);
    list.append(card);
  }
}
async function refresh() {
  const s = await call<Snapshot>("snapshot");
  if (!isOrb) {
    applySettings(s.settings);
    history(s.history);
    $("#openai-state").textContent = s.openaiKey ? "已安全保存" : "未设置";
    $("#deepseek-state").textContent = s.deepseekKey ? "已安全保存" : "可选";
    $("#permission").textContent = s.accessibility
      ? "辅助功能权限已就绪"
      : "自动插入需要辅助功能权限";
  }
  status(s.status);
}
if (!isOrb) {
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !event.repeat &&
        ["listening", "transcribing", "polishing", "rewriting", "inserting"].includes(current.phase)) {
      event.preventDefault();
      void action("cancel");
    }
  });
  document.querySelectorAll<HTMLButtonElement>(".nav").forEach(
    (b) =>
      (b.onclick = () => {
        activePage = b.dataset.page!;
        orb.setVisible(mainVisible && activePage === "voice");
        document
          .querySelectorAll<HTMLElement>(".page")
          .forEach((p) => (p.hidden = p.id !== `page-${b.dataset.page}`));
        document
          .querySelectorAll(".nav")
          .forEach((n) => n.classList.toggle("active", n === b));
      }),
  );
  $("#toggle").onclick = () => action("toggle");
  $("#cancel").onclick = () => action("cancel");
  $("#retry").onclick = () => action("retry");
  $("#copy").onclick = () =>
    action("copy_text", { text: $<HTMLTextAreaElement>("#result").value });
  $("#permissions").onclick = async () => {
    await action("request_accessibility");
    await refresh().catch(notify);
  };
  $("#clear-history").onclick = async () => {
    if (confirm("清空所有本地历史和内存中的重试录音？")) {
      await action("clear_history");
      await refresh().catch(notify);
    }
  };
  document.querySelectorAll<HTMLButtonElement>("[data-save-key]").forEach(
    (b) =>
      (b.onclick = async () => {
        const provider = b.dataset.saveKey!;
        const input = $<HTMLInputElement>(`#${provider}-key`);
        try {
          await call("save_api_key", { provider, value: input.value });
          input.value = "";
          notify("密钥已保存到系统密钥存储");
          await refresh();
        } catch (e) {
          notify(e);
        }
      }),
  );
  document.querySelectorAll<HTMLButtonElement>("[data-test-key]").forEach(
    (b) =>
      (b.onclick = async () => {
        b.disabled = true;
        try {
          await call("test_api_key", { provider: b.dataset.testKey });
          notify("连接和认证成功");
        } catch (e) {
          notify(e);
        } finally {
          b.disabled = false;
        }
      }),
  );
  document.querySelectorAll<HTMLButtonElement>("[data-delete-key]").forEach(
    (b) =>
      (b.onclick = async () => {
        if (confirm("删除这个服务的 API Key？")) {
          await action("delete_api_key", { provider: b.dataset.deleteKey });
          await refresh().catch(notify);
        }
      }),
  );
  $("#cleanup-provider").onchange = () => {
    $<HTMLInputElement>("#cleanup-model").value =
      $<HTMLSelectElement>("#cleanup-provider").value === "deepseek"
        ? "deepseek-v4-flash"
        : "gpt-5.6-luna";
  };
  $("#remember-history").onchange = () => {
    if (!$<HTMLInputElement>("#remember-history").checked)
      $<HTMLInputElement>("#use-history-context").checked = false;
  };
  $("#settings-form").onsubmit = async (e) => {
    e.preventDefault();
    try {
      const s: Settings = {
        ...settings,
        shortcut: $<HTMLInputElement>("#shortcut").value.trim(),
        transcriptionModel: $<HTMLInputElement>(
          "#transcription-model",
        ).value.trim(),
        cleanupProvider: $<HTMLSelectElement>("#cleanup-provider").value,
        cleanupModel: $<HTMLInputElement>("#cleanup-model").value.trim(),
        inputDevice: $<HTMLSelectElement>("#input-device").value,
        dictionary: [
          ...new Set(
            $<HTMLTextAreaElement>("#dictionary")
              .value.split("\n")
              .map((t) => t.trim())
              .filter(Boolean),
          ),
        ],
        autoInsert: $<HTMLInputElement>("#auto-insert").checked,
        selectionEditing: $<HTMLInputElement>("#selection-editing").checked,
        rememberHistory: $<HTMLInputElement>("#remember-history").checked,
        useHistoryContext: $<HTMLInputElement>("#use-history-context").checked,
      };
      if (
        settings.rememberHistory &&
        !s.rememberHistory &&
        !confirm("关闭本地历史会删除已保存的历史，继续吗？")
      )
        return;
      await call("save_settings", { settings: s });
      await refresh();
      notify("设置已保存，快捷键立即生效");
    } catch (error) {
      notify(error);
    }
  };
}
if (preview) {
  if (!isOrb) {
    applySettings({
      shortcut: "CommandOrControl+Shift+Space",
      transcriptionModel: "gpt-transcribe",
      cleanupProvider: "deepseek",
      cleanupModel: "deepseek-v4-flash",
      dictionary: ["skill", "layer", "core"],
      autoInsert: true,
      rememberHistory: false,
      useHistoryContext: false,
      selectionEditing: true,
      inputDevice: "",
    });
    history([]);
    $("#message").textContent = "界面预览 · 桌面 App 中可录音";
  }
} else {
  await listen<boolean>(isOrb ? "orb-visibility" : "main-visibility", (e) => {
    if (isOrb) orb.setVisible(e.payload);
    else {
      mainVisible = e.payload;
      orb.setVisible(mainVisible && activePage === "voice");
    }
  });
  await listen<Status>("voice-status", (e) => status(e.payload));
  await listen<{ level: number; elapsed: number }>("voice-meter", (e) => {
    orb.setLevel(e.payload.level);
    if (!isOrb && current.phase === "listening")
      $("#message").textContent =
        `${e.payload.elapsed.toFixed(1)} / 600 秒 · 再按一次快捷键结束 · Esc 取消`;
  });
  if (!isOrb) {
    await listen("history-updated", async () => {
      const s = await call<Snapshot>("snapshot");
      history(s.history);
    });
    try {
      const devices = await call<string[]>("input_devices");
      for (const device of devices) {
        const o = document.createElement("option");
        o.value = device;
        o.textContent = device;
        $("#input-device").append(o);
      }
    } catch (e) {
      notify(e);
    }
  }
  await refresh().catch(notify);
}
window.addEventListener("beforeunload", () => orb.destroy());
