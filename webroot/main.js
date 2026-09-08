(function () {
  "use strict";

  // customize.sh copies common/apply.sh to $MODPATH/apply.sh, and $MODPATH
  // for an installed module is always /data/adb/modules/<module_id>. The
  // literal "${MODDIR}" token is substituted by KernelSU / KernelSU Next /
  // APatch's WebUI runtime before exec, but Magisk's WebUI (also listed as
  // supported in module.prop) does not perform that substitution — so we
  // resolve the real path ourselves instead of relying on it.
  var MODULE_ID = "yuki_bootanim_installer"; // must match module.prop's id=
  var MODDIR_APPLY = "/data/adb/modules/" + MODULE_ID + "/apply.sh";
  var DATADIR = "/data/adb/yuki_bootanim_installer";

  // Real device payloads are comfortably a few MB; 48 KB of base64 per
  // exec() call stays well under every root manager bridge's known argv /
  // string-length limits while keeping the chunk count reasonable.
  var CHUNK_SIZE = 48 * 1024;

  var els = {};

  function cacheEls() {
    els.deviceLine = document.getElementById("deviceLine");
    els.kvManager = document.getElementById("kvManager");
    els.kvApi = document.getElementById("kvApi");
    els.kvFormat = document.getElementById("kvFormat");
    els.kvMount = document.getElementById("kvMount");
    els.metamoduleWarning = document.getElementById("metamoduleWarning");
    els.metamoduleWarningText = document.getElementById("metamoduleWarningText");

    els.currentPanel = document.getElementById("currentPanel");
    els.currentFileName = document.getElementById("currentFileName");
    els.currentFileTime = document.getElementById("currentFileTime");

    els.pickerLabel = document.getElementById("pickerLabel");
    els.pickerText = document.getElementById("pickerText");
    els.fileInput = document.getElementById("fileInput");

    els.fileBar = document.getElementById("fileBar");
    els.fileBarName = document.getElementById("fileBarName");
    els.fileBarSize = document.getElementById("fileBarSize");
    els.fileBarClear = document.getElementById("fileBarClear");

    els.validationError = document.getElementById("validationError");

    els.applyBtn = document.getElementById("applyBtn");
    els.applyBtnText = document.getElementById("applyBtnText");

    els.logPanel = document.getElementById("logPanel");
    els.logOutput = document.getElementById("logOutput");
  }

  function hasExecBridge() {
    return typeof window.ksu !== "undefined" && typeof window.ksu.exec === "function";
  }

  var execCallbackCounter = 0;
  function uniqueCallbackName() {
    return "yukiBootanimExecCb_" + Date.now().toString(36) + "_" + execCallbackCounter++;
  }

  /**
   * Low-level wrapper around the real window.ksu.exec(command, optionsJson,
   * callbackName) native bridge. Registers a temporary, uniquely-named
   * global function that the native side calls back with
   * (errno, stdout, stderr), resolves the returned Promise from inside it,
   * then cleans the temporary global up. Never throws on a non-zero errno
   * by itself — that's for the caller (shExec below) to interpret, since a
   * non-zero errno with real stdout is a normal, expected outcome for some
   * commands.
   */
  function ksuExecRaw(cmd) {
    return new Promise(function (resolve, reject) {
      if (!hasExecBridge()) {
        reject(new Error("No root shell bridge (window.ksu.exec) is available in this WebView."));
        return;
      }
      var cbName = uniqueCallbackName();
      window[cbName] = function (errno, stdout, stderr) {
        delete window[cbName];
        resolve({ errno: errno, stdout: stdout || "", stderr: stderr || "" });
      };
      try {
        window.ksu.exec(cmd, "{}", cbName);
      } catch (err) {
        delete window[cbName];
        reject(err);
      }
    });
  }

  /**
   * Runs a shell command as root and returns stdout (trimmed).
   * Throws if the bridge is unavailable or the command's own errno is
   * non-zero AND produced no stdout at all (apply.sh always exits 0 and
   * reports failure via its JSON body instead, so a thrown error here
   * means something more fundamental broke, e.g. the bridge itself, or
   * apply.sh not existing on disk yet).
   */
  async function shExec(cmd) {
    var result = await ksuExecRaw(cmd);
    var stdout = result.stdout || "";
    if (result.errno !== 0 && !stdout.trim()) {
      var stderr = (result.stderr || "").trim();
      // customize.sh only copies apply.sh into $MODPATH during the actual
      // flash — if the module was just installed/updated and the device
      // hasn't rebooted since, the file genuinely doesn't exist yet. This
      // is common enough (impatient users opening WebUI right after
      // flashing) to deserve a specific message instead of a raw shell error.
      if (/apply\.sh.*(not found|no such file)/i.test(stderr) || (cmd.indexOf(MODDIR_APPLY) !== -1 && /not found|no such file/i.test(stderr))) {
        throw new Error("apply.sh not found yet \u2014 reboot once after installing or updating this module, then reopen this page.");
      }
      throw new Error(stderr || "Command failed with no output.");
    }
    return stdout.trim();
  }

  /** Quote a single argument for /system/bin/sh (POSIX single-quote style). */
  function shQuote(arg) {
    return "'" + String(arg).replace(/'/g, "'\\''") + "'";
  }

  var ROOT_MGR_LABELS = {
    ksu: "KernelSU / KernelSU Next",
    apatch: "APatch",
    magisk: "Magisk",
    unknown: "Not recognized",
  };

  function parseConf(text) {
    var out = {};
    text.split("\n").forEach(function (line) {
      line = line.trim();
      if (!line || line.charAt(0) === "#") return;
      var eq = line.indexOf("=");
      if (eq === -1) return;
      var key = line.slice(0, eq).trim();
      var val = line.slice(eq + 1).trim();
      // Strip one layer of surrounding quotes, if present (state.conf now
      // quotes every value; device.conf's ROM_MEDIA_CANDIDATES line does too).
      if (
        val.length >= 2 &&
        ((val.charAt(0) === '"' && val.charAt(val.length - 1) === '"') ||
          (val.charAt(0) === "'" && val.charAt(val.length - 1) === "'"))
      ) {
        val = val.slice(1, -1);
      }
      out[key] = val;
    });
    return out;
  }

  async function loadDeviceStatus() {
    var text;
    try {
      text = await shExec("cat " + shQuote(DATADIR + "/device.conf") + " 2>/dev/null");
    } catch (err) {
      text = "";
    }

    if (!text) {
      els.deviceLine.textContent = "Device detection has not run yet — reboot after installing the module.";
      els.kvManager.textContent = "\u2014";
      els.kvApi.textContent = "\u2014";
      els.kvFormat.textContent = "\u2014";
      els.kvMount.textContent = "\u2014";
      // Nothing usable in device.conf: keep the apply button disabled with
      // a clear reason rather than letting the user hit an opaque failure
      // later inside apply.sh.
      setApplyDisabledReason("Device info unavailable \u2014 reboot first");
      return null;
    }

    var conf = parseConf(text);
    var isSamsung = conf.IS_SAMSUNG === "true";
    var hasMeta = conf.HAS_METAMODULE === "true";

    els.deviceLine.textContent = isSamsung
      ? "Samsung device \u2014 One UI (.qmg format)"
      : "Standard boot animation format (.zip)";

    els.kvManager.textContent = ROOT_MGR_LABELS[conf.ROOT_MGR] || conf.ROOT_MGR || "\u2014";
    els.kvApi.textContent = conf.API ? "API " + conf.API : "\u2014";
    els.kvFormat.textContent = isSamsung ? ".qmg (Samsung)" : ".zip (standard)";

    var candidates = (conf.ROM_MEDIA_CANDIDATES || conf.SYSTEM_MEDIA || "/system/media")
      .split(/\s+/)
      .filter(Boolean);
    els.kvMount.textContent = candidates.length > 1 ? candidates[0] + " (+" + (candidates.length - 1) + ")" : candidates[0];
    if (candidates.length > 1) {
      els.kvMount.title = "Candidate paths, in order of preference: " + candidates.join(", ");
    }

    if (conf.ROOT_MGR === "ksu" && !hasMeta) {
      els.metamoduleWarning.hidden = false;
      els.metamoduleWarningText.textContent =
        "If direct remount to /system fails on this device, a metamodule (Hybrid-Mount or Mountify) will be required to install via the overlay path.";
    } else {
      els.metamoduleWarning.hidden = true;
    }

    return conf;
  }

  async function loadCurrentState() {
    var text;
    try {
      text = await shExec("cat " + shQuote(DATADIR + "/state.conf") + " 2>/dev/null");
    } catch (err) {
      text = "";
    }
    if (!text) {
      els.currentPanel.hidden = true;
      return;
    }
    var state = parseConf(text);
    if (!state.LAST_APPLIED_FILE) {
      els.currentPanel.hidden = true;
      return;
    }
    els.currentPanel.hidden = false;
    els.currentFileName.textContent = state.LAST_APPLIED_FILE;
    els.currentFileTime.textContent = state.LAST_APPLIED_TIME || "";
  }

  var selectedFile = null;
  var applyDisabledReason = "Select the file first";

  function setApplyDisabledReason(text) {
    applyDisabledReason = text;
    refreshApplyButton();
  }

  function refreshApplyButton() {
    if (selectedFile) {
      els.applyBtn.disabled = false;
      els.applyBtnText.textContent = "Install boot animation";
      els.applyBtn.classList.remove("is-danger");
    } else {
      els.applyBtn.disabled = true;
      els.applyBtnText.textContent = applyDisabledReason;
    }
  }

  function formatSize(bytes) {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
    return (bytes / (1024 * 1024)).toFixed(2) + " MB";
  }

  function getExt(name) {
    var m = /\.([a-zA-Z0-9]+)$/.exec(name || "");
    return m ? m[1].toLowerCase() : "";
  }

  function showValidationError(msg) {
    if (!msg) {
      els.validationError.hidden = true;
      els.validationError.textContent = "";
      return;
    }
    els.validationError.hidden = false;
    els.validationError.textContent = msg;
  }

  function clearSelection() {
    selectedFile = null;
    els.fileInput.value = "";
    els.fileBar.hidden = true;
    showValidationError(null);
    setApplyDisabledReason("Select the file first");
  }

  function onFilePicked(file) {
    showValidationError(null);

    var ext = getExt(file.name);
    if (ext !== "zip" && ext !== "qmg") {
      selectedFile = null;
      els.fileBar.hidden = true;
      showValidationError("The ." + (ext || "?") + " extension is not supported. Pick a .zip or .qmg file.");
      setApplyDisabledReason("Select the file first");
      return;
    }
    if (file.size === 0) {
      selectedFile = null;
      els.fileBar.hidden = true;
      showValidationError("The selected file is empty (0 bytes).");
      setApplyDisabledReason("Select the file first");
      return;
    }

    selectedFile = file;
    els.fileBarName.textContent = file.name;
    els.fileBarSize.textContent = formatSize(file.size);
    els.fileBar.hidden = false;
    refreshApplyButton();
  }

  function logLine(text) {
    els.logPanel.hidden = false;
    var stamp = new Date().toLocaleTimeString();
    els.logOutput.textContent += "[" + stamp + "] " + text + "\n";
    els.logOutput.scrollTop = els.logOutput.scrollHeight;
  }

  function resetLog() {
    els.logOutput.textContent = "";
    els.logPanel.hidden = true;
  }

  function readFileAsBase64(file) {
    return new Promise(function (resolve, reject) {
      var reader = new FileReader();
      reader.onload = function () {
        // reader.result is "data:<mime>;base64,<data>" — strip the prefix.
        var result = reader.result;
        var comma = result.indexOf(",");
        resolve(comma === -1 ? result : result.slice(comma + 1));
      };
      reader.onerror = function () {
        reject(new Error("Failed to read the file from disk."));
      };
      reader.readAsDataURL(file);
    });
  }

  function makeUploadId() {
    return "up" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }

  /**
   * Sends the whole base64 payload through apply.sh's chunk protocol, then
   * calls finish. Returns the parsed JSON result from the final `finish`
   * invocation (which is the actual install outcome, since finish chains
   * straight into the install logic once assembly succeeds).
   */
  async function chunkUpload(base64Data, originalName) {
    var uploadId = makeUploadId();
    var total = Math.ceil(base64Data.length / CHUNK_SIZE);

    logLine("Starting transfer: " + total + " chunk(s), " + formatSize(base64Data.length) + " of base64 data.");

    for (var i = 0; i < total; i++) {
      var piece = base64Data.slice(i * CHUNK_SIZE, (i + 1) * CHUNK_SIZE);
      var cmd =
        shQuote(MODDIR_APPLY) +
        " chunk " +
        shQuote(uploadId) +
        " " +
        i +
        " " +
        shQuote(piece);

      var out;
      try {
        out = await shExec(cmd);
      } catch (err) {
        throw new Error("Transfer failed at chunk " + i + "/" + total + ": " + err.message);
      }

      var parsed = safeParseJson(out);
      if (!parsed || parsed.ok !== true) {
        var msg = (parsed && parsed.message) || "Unknown error sending chunk " + i + ".";
        // Best-effort cleanup of the partial upload on the shell side —
        // failure here shouldn't mask the original error.
        try {
          await shExec(shQuote(MODDIR_APPLY) + " abort " + shQuote(uploadId));
        } catch (cleanupErr) {
          /* ignore */
        }
        throw new Error(msg);
      }

      if (total > 1) {
        logLine("Sent chunk " + (i + 1) + "/" + total + ".");
      }
    }

    logLine("All chunks sent. Assembling and installing on-device\u2026");

    var finishCmd =
      shQuote(MODDIR_APPLY) + " finish " + shQuote(uploadId) + " " + shQuote(originalName);

    var finishOut;
    try {
      finishOut = await shExec(finishCmd);
    } catch (err) {
      throw new Error("Failed to finalize the transfer: " + err.message);
    }

    var finishResult = safeParseJson(finishOut);
    if (!finishResult) {
      throw new Error("The install script returned an unreadable response:\n" + finishOut);
    }
    return finishResult;
  }

  function safeParseJson(text) {
    try {
      return JSON.parse(text);
    } catch (err) {
      return null;
    }
  }

  function renderResult(result) {
    if (result.ok) {
      logLine("\u2713 " + result.message);
      if (result.reboot_required) {
        logLine("Reboot your device to see the new boot animation.");
      }
      showValidationError(null);
      els.applyBtn.classList.remove("is-danger");
    } else {
      logLine("\u2717 [" + (result.stage || "error") + "] " + result.message);
      showValidationError(result.message);
      els.applyBtn.classList.add("is-danger");

      if (result.stage === "no_metamodule" && Array.isArray(result.suggest_metamodules)) {
        logLine("Suggested metamodules: " + result.suggest_metamodules.join(", "));
      }
      if (result.stage === "samsung_guard") {
        // The picked file is fundamentally the wrong format for this
        // device — clear the selection so the user doesn't retry the same
        // file expecting a different outcome.
        clearSelection();
      }
    }
  }

  async function runApply() {
    if (!selectedFile) return;

    resetLog();
    els.applyBtn.disabled = true;
    var originalBtnText = els.applyBtnText.textContent;
    els.applyBtnText.textContent = "Installing\u2026";
    showValidationError(null);

    try {
      logLine("Reading " + selectedFile.name + " (" + formatSize(selectedFile.size) + ")\u2026");
      var base64Data = await readFileAsBase64(selectedFile);

      var result = await chunkUpload(base64Data, selectedFile.name);
      renderResult(result);

      if (result.ok) {
        await loadCurrentState();
        clearSelection();
      }
    } catch (err) {
      logLine("\u2717 " + err.message);
      showValidationError(err.message);
      els.applyBtn.classList.add("is-danger");
    } finally {
      // refreshApplyButton() will correctly re-disable if clearSelection()
      // already ran above; this only matters for the failure path where
      // selectedFile is still set and the button should become clickable
      // again for a retry.
      if (selectedFile) {
        els.applyBtn.disabled = false;
        els.applyBtnText.textContent = originalBtnText;
      } else {
        refreshApplyButton();
      }
    }
  }

  function bindEvents() {
    els.fileInput.addEventListener("change", function () {
      var file = els.fileInput.files && els.fileInput.files[0];
      if (file) onFilePicked(file);
    });

    els.fileBarClear.addEventListener("click", function (evt) {
      evt.preventDefault();
      clearSelection();
    });

    els.applyBtn.addEventListener("click", function () {
      runApply();
    });
  }

  async function init() {
    cacheEls();
    bindEvents();
    refreshApplyButton();

    if (!hasExecBridge()) {
      els.deviceLine.textContent = "No root shell bridge detected \u2014 open this page from your root manager app.";
      setApplyDisabledReason("Root bridge unavailable");
      return;
    }

    try {
      await loadDeviceStatus();
      await loadCurrentState();
    } catch (err) {
      els.deviceLine.textContent = "Failed to read device status: " + err.message;
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();