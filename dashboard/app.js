(() => {
  const api = new URLSearchParams(window.location.search).get("api") || "";
  const base = api.replace(/\/$/, "");
  const elements = {
    connection: document.querySelector("#connection"),
    median: document.querySelector("#median"),
    participants: document.querySelector("#participants"),
    roundCount: document.querySelector("#round-count"),
    rounds: document.querySelector("#rounds"),
    updated: document.querySelector("#updated"),
  };

  const formatSeconds = (value) =>
    typeof value === "number" && Number.isFinite(value)
      ? `${value.toFixed(1)} s`
      : "—";

  const escapeHtml = (value) =>
    String(value ?? "").replace(/[&<>"']/g, (character) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#039;",
    }[character]));

  async function fetchJson(path) {
    const response = await fetch(`${base}${path}`, { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`Request failed: ${response.status}`);
    }
    return response.json();
  }

  function renderRounds(rounds) {
    const validRounds = rounds.filter(
      (round) => round.success === true && round.isPractice === false
    );
    elements.roundCount.textContent = validRounds.length;
    if (rounds.length === 0) {
      elements.rounds.innerHTML =
        '<tr><td colspan="4" class="empty">No rounds yet.</td></tr>';
      return;
    }

    elements.rounds.innerHTML = rounds.map((round) => {
      const result = round.success ? "Found" : "Unsuccessful";
      const resultClass = round.success ? "success" : "failure";
      return `
        <tr>
          <td>${escapeHtml(round.participantId)}</td>
          <td>${escapeHtml(round.objectLabel)}</td>
          <td>${formatSeconds(round.durationSeconds)}</td>
          <td><span class="status ${resultClass}">${result}</span></td>
        </tr>`;
    }).join("");
  }

  async function refresh() {
    try {
      const [stats, rounds] = await Promise.all([
        fetchJson("/api/stats"),
        fetchJson("/api/rounds?limit=10"),
      ]);
      elements.median.textContent = formatSeconds(stats.medianEchoraSeconds);
      elements.participants.textContent = stats.participants ?? "—";
      renderRounds(rounds);
      elements.connection.textContent = "Backend connected";
      elements.connection.className = "connection online";
      elements.updated.textContent = `Updated ${new Date().toLocaleTimeString()}`;
    } catch (error) {
      elements.connection.textContent = "Backend unavailable";
      elements.connection.className = "connection offline";
      console.error("Dashboard refresh failed", error);
    }
  }

  refresh();
  window.setInterval(refresh, 3000);
})();
