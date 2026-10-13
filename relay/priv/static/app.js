// Glacier Relay dashboard client (M3-B): connects the LiveView socket. Nothing else runs in
// the browser; every interaction is a LiveView event that changes presentation only.
(function () {
  var meta = document.querySelector("meta[name='csrf-token']");
  var token = meta ? meta.getAttribute("content") : null;
  var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
    params: { _csrf_token: token }
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
