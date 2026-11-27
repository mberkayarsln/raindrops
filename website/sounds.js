(() => {
  const buttons = [...document.querySelectorAll(".sound")];
  if (!buttons.length) return;

  const AudioContextClass = window.AudioContext || window.webkitAudioContext;
  const buffers = new Map();
  const fade = 0.35;
  let context = null;
  let output = null;
  let current = null;

  const setPressed = (active) => {
    buttons.forEach((button) => button.setAttribute("aria-pressed", String(button === active)));
  };

  const load = async (src) => {
    if (!buffers.has(src)) {
      buffers.set(src, fetch(src)
        .then((response) => response.arrayBuffer())
        .then((data) => new Promise((resolve, reject) => context.decodeAudioData(data, resolve, reject))));
    }
    try {
      return await buffers.get(src);
    } catch (error) {
      buffers.delete(src);
      throw error;
    }
  };

  const element = new Audio();
  element.loop = true;

  const stop = () => {
    element.pause();
    if (!current) return;
    const { source, gain } = current;
    const now = context.currentTime;
    gain.gain.cancelScheduledValues(now);
    gain.gain.setValueAtTime(gain.gain.value, now);
    gain.gain.linearRampToValueAtTime(0, now + fade);
    source.stop(now + fade + 0.05);
    current = null;
  };

  const play = async (button) => {
    if (!context) {
      if (navigator.audioSession) navigator.audioSession.type = "playback";
      context = new AudioContextClass();
      output = context.createGain();
      output.gain.value = 0.9;
      output.connect(context.destination);
    }
    if (context.state === "suspended") await context.resume();
    stop();
    setPressed(button);
    button.classList.add("is-loading");
    let buffer;
    try {
      buffer = await load(button.dataset.src);
    } catch {
      button.classList.remove("is-loading");
      setPressed(null);
      return;
    }
    button.classList.remove("is-loading");
    if (button.getAttribute("aria-pressed") !== "true") return;
    const source = context.createBufferSource();
    const gain = context.createGain();
    source.buffer = buffer;
    source.loop = true;
    source.connect(gain).connect(output);
    const now = context.currentTime;
    gain.gain.setValueAtTime(0, now);
    gain.gain.linearRampToValueAtTime(1, now + fade);
    source.start(now);
    current = { source, gain };
  };

  if (!AudioContextClass || location.protocol === "file:") {
    buttons.forEach((button) => button.addEventListener("click", () => {
      element.pause();
      if (button.getAttribute("aria-pressed") === "true") {
        setPressed(null);
        return;
      }
      setPressed(button);
      element.src = button.dataset.src;
      element.play().catch(() => setPressed(null));
    }));
    return;
  }

  buttons.forEach((button) => button.addEventListener("click", () => {
    if (button.getAttribute("aria-pressed") === "true") {
      stop();
      setPressed(null);
      return;
    }
    play(button);
  }));
})();
