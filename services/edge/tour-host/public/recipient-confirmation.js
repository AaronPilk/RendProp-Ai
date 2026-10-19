/* The nonce stays in memory and the form body; never place it in a query,
 * storage, logs, analytics, or a referrer. GET does not confirm the address. */
(() => {
  const token = new URLSearchParams(window.location.hash.slice(1)).get("token");
  window.history.replaceState(null, "", window.location.pathname);
  const input = document.getElementById("token");
  const button = document.getElementById("confirm");
  if (input && button && token && /^[a-f0-9]{64}$/i.test(token)) {
    input.value = token;
    button.disabled = false;
  } else {
    const message = document.getElementById("message");
    if (message) message.textContent = "Open the complete confirmation link from your email. If it has expired, ask for a new link.";
  }
})();
