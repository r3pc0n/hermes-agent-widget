import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Hermes Agent Widget — usage, balance, and a model switcher: one bar
// icon and one panel. Data is fetched directly from the configured Hermes
// bridge URL via QML HTTP requests.
Panel {
  id: root
  moduleName: "io.github.r3pc0n.hermes-agent-widget"
  ipcTarget: "io.github.r3pc0n.hermes-agent-widget"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property color track: Style.selectedFillFor(foreground, accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property url iconSource: Qt.resolvedUrl("assets/hermes-icon.png")
  readonly property string bridgeScript: String(Qt.resolvedUrl("bridge.py")).replace(/^file:\/\//, "")

  property var stats: null
  property bool refreshing: false
  property string applyingModel: ""
  property bool cursorActive: false
  property int modelCursor: 0
  // Accordion state: which provider group is expanded ("" = none).
  property string expandedProvider: ""
  property string prevModel: ""
  property bool settingsVisible: false
  property var uiSettings: ({})
  property bool chatActive: false
  property var chatMessages: []
  property bool chatBusy: false

  readonly property var api: stats && stats.api ? stats.api : null
  readonly property var usage: stats && stats.usage ? stats.usage : null
  readonly property var hermes: stats && stats.hermes ? stats.hermes : null
  readonly property var keyUsage: api && api.keyUsage ? api.keyUsage : null
  readonly property var lastSessions: usage && Array.isArray(usage.recentSessions) ? usage.recentSessions : []
  readonly property var models: stats && Array.isArray(stats.models) ? stats.models : []
  readonly property int profileCount: hermes ? Math.max(1, Number(hermes.profileCount || 1)) : 1
  readonly property string profileScope: profileCount === 1 ? "1 Hermes profile" : profileCount + " Hermes profiles"

  // Provider-grouped switcher rows: [{kind:"header",...}] + [{kind:"model",...}]
  // for the expanded group only. Recomputes when stats/expandedProvider change.
  readonly property var modelGroups: root.computeModelGroups()
  readonly property var modelRows: root.buildModelRows()

  readonly property string currentModel: hermes ? String(hermes.model || "") : ""
  readonly property string updatedAt: stats ? String(stats.updated || "") : ""
  readonly property real remaining: api && api.balanceAvailable === true && isFinite(api.remaining) ? api.remaining : -1
  readonly property real funded: api && api.ok && isFinite(api.total) ? api.total : 0
  readonly property real spent: api && api.ok && isFinite(api.used) ? api.used : 0
  // The meter shows the USED fraction of the topped-up balance (grows as
  // credits are consumed), while the alarm fires on the remaining fraction.
  readonly property real ratio: funded > 0 ? clamp(spent / funded, 0, 1) : -1
  readonly property bool alarming: remaining >= 0 && funded > 0 && (remaining / funded) <= 0.1

  // The bar sizes the slot from the widget root's implicit size. Match the
  // native icon slot (27px) so the button's fixedWidth/iconCanvas center
  // properly. The button must have visual content (text or iconComponent) —
  // BarIconButton's hasVisualContent gates whether the bar renders it at all.
  implicitWidth: Style.bar.iconSlot
  implicitHeight: Style.bar.iconSlot

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Inline settings are injected from this plugin's shell.json entry by the
  // bar. Keep defaults here so older installs gain the controls safely.
  function settingValue(name, fallback) {
    var value = root.uiSettings && root.uiSettings[name] !== undefined
      ? root.uiSettings[name]
      : (root.settings ? root.settings[name] : undefined)
    return value === undefined || value === null ? fallback : value
  }

  function settingBool(name, fallback) {
    var value = settingValue(name, fallback)
    return value === true || value === 1 || String(value).toLowerCase() === "true"
  }

  function saveSettings(changes) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") {
      console.warn("hermes-agent-widget: shell settings API unavailable")
      return
    }
    var next = ({})
    var base = root.uiSettings || root.settings || ({})
    for (var existing in base) if (existing !== "id") next[existing] = base[existing]
    for (var change in changes) next[change] = changes[change]
    root.uiSettings = next

    var entry = ({ id: moduleName })
    base = next
    for (var key in base) if (key !== "id") entry[key] = base[key]
    for (var change in changes) entry[change] = changes[change]
    bar.shell.updateEntryInline(moduleName, entry)
  }

  function saveSetting(name, value) {
    var changes = ({})
    changes[name] = value
    saveSettings(changes)
  }

  function bridgeUrl() {
    var val = settingValue("bridgeUrl", "")
    return val === "" ? "http://your-hermes:8643" : String(val)
  }

  function bridgeToken() {
    // Local and Remote modes use separate stored tokens so switching
    // modes doesn't overwrite the other.
    if (root.localMode())
      return String(settingValue("localToken", "") || "")
    return String(settingValue("remoteToken", "") || "")
  }

  function localMode() { return String(settingValue("connectionMode", "local")) === "local" }
  function loadSettings() {
    var loaded = ({})
    var source = root.settings || ({})
    for (var key in source) if (key !== "id") loaded[key] = source[key]
    if (!loaded.bridgeUrl || loaded.bridgeUrl === "") loaded.connectionMode = "local"
    root.uiSettings = loaded
  }
  function showBalance() { return settingBool("balanceVisible", true) }
  function showDayChart() { return settingBool("tokensByDayVisible", true) }
  function showModelUsage() { return settingBool("modelUsageVisible", true) }
  function showProviderAccordion() { return settingBool("providerAccordionVisible", true) }
  function showRecentSessions() { return settingBool("recentSessionsVisible", true) }

  function val(o, k, fallback) {
    return o && o[k] !== undefined && o[k] !== null ? o[k] : fallback
  }

  function fmtTokens(n) {
    var v = Number(n || 0)
    if (v >= 1e9) return (v / 1e9).toFixed(1) + "B"
    if (v >= 1e6) return (v / 1e6).toFixed(1) + "M"
    if (v >= 1e3) return (v / 1e3).toFixed(1) + "k"
    return String(Math.round(v))
  }

  function fmtMoney(f) {
    var v = Number(f || 0)
    return "$" + v.toFixed(2)
  }

  function fmtCtx(n) {
    var v = Number(n || 0)
    if (v >= 1e9) return (v / 1e9).toFixed(1) + "B"
    if (v >= 1e6) return (v / 1e6).toFixed(0) + "M"
    if (v >= 1e3) return (v / 1e3).toFixed(0) + "k"
    return v > 0 ? String(v) : ""
  }

  // Preferred cost for a summary card: the bridge's spent figure for
  // this key when available, else the local Hermes estimate.
  // kind: keyUsage field name ("daily"|"weekly"|"total"|"monthly").
  function cardCost(kind, estimate) {
    var k = root.keyUsage
    if (k && isFinite(Number(k[kind]))) return Number(k[kind])
    return Number(estimate || 0)
  }

  // "deepseek/deepseek-v4-flash-0731" -> "deepseek-v4-flash-0731"
  function shortModel(id) {
    var s = String(id || "")
    var slash = s.lastIndexOf("/")
    return slash >= 0 ? s.slice(slash + 1) : s
  }

  // Slashed ids are OpenRouter-routed today (deepseek/..., qwen/...); direct
  // DeepSeek ids are bare. Tag the row so it can't be mistaken for direct.
  function modelTag(id) {
    return String(id || "").indexOf("/") >= 0 ? "OpenRouter" : ""
  }

  function modelDisplay(id) {
    var base = root.shortModel(id)
    var tag = root.modelTag(id)
    return tag ? base + "  ·  " + tag : base
  }

  function p2(n) {
    n = String(n)
    return n.length < 2 ? "0" + n : n
  }

  function isoDate(d) {
    return d.getFullYear() + "-" + p2(d.getMonth() + 1) + "-" + p2(d.getDate())
  }

  function todayDate() {
    return isoDate(new Date())
  }

  function heroTitle() {
    if (currentModel !== "") return shortModel(currentModel)
    return "Hermes"
  }

  function providerName(p) {
    p = String(p || "deepseek")
    if (p === "openrouter") return "OpenRouter"
    if (p === "deepseek") return "DeepSeek"
    return p.charAt(0).toUpperCase() + p.slice(1)
  }

  function providerLabel() {
    return root.providerName(root.currentProvider())
  }

  function providerUrl() {
    // Construct the Hermes dashboard URL from the bridge host + dashboard port.
    var port = root.hermes && root.hermes.dashboardPort
    var home = root.hermes && root.hermes.home
    if (port > 0 && home) {
      var host = home.replace(/^https?:\/\//, "").replace(/:.*$/, "")
      if (host) return "http://" + host + ":" + port
    }
    // Fallback: provider-specific usage pages.
    var p = root.currentProvider()
    if (p === "deepseek") return "https://platform.deepseek.com/usage"
    if (p === "openrouter") return "https://openrouter.ai/activity"
    return ""
  }

  function currentProvider() {
    return hermes && hermes.provider ? String(hermes.provider) : "deepseek"
  }

  function heroMeta() {
    var label = root.providerLabel()
    if (!api || !api.ok) return label + " · " + (api && api.configured ? "bridge unreachable" : "no data")
    if (api.balanceAvailable === false || remaining < 0) return label + " · Connected"
    return label + " · " + fmtMoney(remaining) + " remaining"
  }

  function statusText() {
    if (api && api.configured && !api.ok)
      return "Usage bridge unreachable — balance unavailable. Usage and the model list still work."
    return ""
  }

  function pricingText(m) {
    if (!m) return ""
    var p = String(val(m, "prompt", ""))
    var c = String(val(m, "completion", ""))
    if (p === "" && c === "") return "free"
    var parts = []
    if (p !== "") parts.push("in " + p)
    if (c !== "") parts.push("out " + c)
    return parts.join(" · ")
  }

  function weekPeak() {
    var peak = 0
    if (usage && Array.isArray(usage.byDay))
      for (var i = 0; i < usage.byDay.length; i++)
        peak = Math.max(peak, Number(usage.byDay[i].tokens || 0))
    return Math.max(1, peak)
  }

  function weekday(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return ""
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date) {
    var s = String(date || "")
    if (s === root.todayDate()) return "Today"
    var wd = root.weekday(s)
    return wd === "" ? s : wd
  }

  function shortTime(iso) {
    var m = String(iso || "").match(/T(\d\d):(\d\d)/)
    return m ? m[1] + ":" + m[2] : ""
  }

  function safeSessionId(val) {
    // Only alphanumeric + underscore — rejects any shell metacharacters
    return String(val || "").replace(/[^a-zA-Z0-9_]/g, "")
  }

  function fetchLocalToken() {
    // In local mode the bridge auto-generates an auth token.  Fetch it on
    // startup so all subsequent requests are authenticated.
    if (!root.localMode() || root.bridgeToken()) return
    root.fetchJson("http://localhost:8643/token", function(resp) {
      if (resp && resp.token) {
        root.saveSetting("localToken", resp.token)
      }
    }, function() {
    }, "GET")
  }

  function fetchJson(url, onSuccess, onError, method, body) {
    var req = new XMLHttpRequest()
    var finished = false
    function fail() {
      if (finished) return
      finished = true
      onError()
    }
    req.timeout = 5000
    req.onreadystatechange = function() {
      if (req.readyState !== XMLHttpRequest.DONE || finished) return
      if (req.status !== 200) { fail(); return }
      var parsed = null
      try { parsed = JSON.parse(req.responseText) } catch (e) { fail(); return }
      if (parsed && typeof parsed === "object") {
        finished = true
        onSuccess(parsed)
      } else fail()
    }
    req.onerror = fail
    req.ontimeout = fail
    try {
      req.open(method || "GET", url)
      var token = root.bridgeToken()
      if (token !== "") req.setRequestHeader("Authorization", "Bearer " + token)
      if (body !== undefined) req.setRequestHeader("Content-Type", "application/json")
      req.send(body === undefined ? null : body)
    } catch (e) { fail() }
  }

  // The bridge needs a /chat endpoint to proxy this request to Hermes.
  // Until then, the normal 404 path is shown as an assistant error message.
  function sendChatMessage(text) {
    var message = String(text || "").trim()
    if (!message || root.chatBusy) return
    var url = root.localMode() ? "http://localhost:8643" : root.bridgeUrl()
    root.chatMessages = root.chatMessages.concat([{ role: "user", text: message }])
    root.chatBusy = true
    fetchJson(url + "/chat", function(resp) {
      root.chatMessages = root.chatMessages.concat([{
        role: "assistant",
        text: resp && resp.response ? String(resp.response) : "(no response from agent)"
      }])
      root.chatBusy = false
    }, function() {
      root.chatMessages = root.chatMessages.concat([{
        role: "assistant",
        text: "(chat unavailable — bridge /chat is not implemented yet)"
      }])
      root.chatBusy = false
    }, "POST", JSON.stringify({ message: message }))
  }

  function money(v) {
    var n = Number(v)
    return isNaN(n) ? 0 : Math.round(n * 10000) / 10000
  }

  function int0(v) {
    var n = Number(v)
    return isNaN(n) ? 0 : Math.floor(n)
  }

  function buildStats(hermesData, modelsData, bridgeUrl) {
    var rec = hermesData || ({})
    var modelResponse = modelsData || ({})
    var ok = Object.keys(rec).length > 0
    var hasBalance = rec.balance !== null && rec.balance !== undefined
    var bal = hasBalance ? rec.balance : ({})
    var byModel = []
    var modelUsage = rec.modelUsage || ({})
    for (var model in modelUsage) {
      var m = modelUsage[model] || ({})
      byModel.push({
        model: model,
        tokens: int0(m.inputTokens) + int0(m.outputTokens) + int0(m.cacheReadInputTokens),
        input: int0(m.inputTokens),
        output: int0(m.outputTokens),
        cache: int0(m.cacheReadInputTokens),
        cost: money(m.cost)
      })
    }
    byModel.sort(function(a, b) { return b.tokens - a.tokens })

    var byDay = []
    var recentDays = rec.recentDays || []
    for (var di = 0; di < recentDays.length; di++) {
      var d = recentDays[di] || ({})
      byDay.push({
        date: d.date || "",
        tokens: int0(d.messageCount),
        cost: money(d.cost),
        costExact: Boolean(d.costExact)
      })
    }

    var agent = rec.agent || rec.echo || ({})
    var listedModels = Array.isArray(modelResponse.models) ? modelResponse.models : []
    return {
      updated: new Date().toISOString(),
      api: {
        configured: true,
        ok: ok,
        balanceAvailable: hasBalance,
        total: money(bal.funded),
        used: money(bal.spent),
        remaining: money(bal.remaining),
        keyUsage: null,
        keyCount: 1,
        keyUsageComplete: false
      },
      hermes: {
        home: bridgeUrl,
        db: bridgeUrl + "/hermes.json",
        config: "model.default via POST /model",
        model: String(modelResponse.current || ""),
        provider: String(agent.provider || "deepseek"),
        profileCount: 1,
        profiles: [root.localMode() ? "local" : "remote"],
        dashboardPort: Number(rec.dashboardPort || 0)
      },
      usage: {
        today: { tokens: int0(rec.todayTotalTokens), cost: money(agent.costToday), calls: int0(rec.todayPrompts) },
        week: { tokens: byDay.reduce(function(s, d) { return s + d.tokens }, 0), cost: money(agent.costWeek), calls: 0 },
        month30: { tokens: int0(agent.tokens30), cost: money(agent.cost30), calls: 0 },
        allTime: { tokens: int0(agent.tokensAllTime), cost: money(agent.costAllTime), calls: 0 },
        byDay: byDay,
        byModel: byModel,
        recentSessions: []
      },
      models: listedModels.filter(function(m) { return m && m.id }).map(function(m) {
        return {
          id: m.id,
          name: m.name || m.id,
          provider: m.provider || "",
          context: 0,
          prompt: "",
          completion: ""
        }
      })
    }
  }

  function fetchFromBridge() {
    if (refreshing) return
    refreshing = true
    var url = root.localMode() ? "http://localhost:8643" : root.bridgeUrl()
    fetchJson(url + "/hermes.json", function(hermesData) {
      fetchJson(url + "/models", function(modelsData) {
        root.stats = root.buildStats(hermesData, modelsData, url)
        refreshing = false
      }, function() {
        root.stats = root.buildStats(hermesData, ({ }), url)
        refreshing = false
      })
    }, function() {
      root.stats = null
      refreshing = false
    })
  }

  function applyModel(id) {
    if (id === "" || id === root.applyingModel) return
    // Switch through the same authenticated bridge used for usage and chat.
    // Only accept well-formed model ids so a compromised model listing cannot
    // inject control characters or an unexpected path-like value.
    id = String(id)
    if (!/^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$/.test(id)) return
    root.applyingModel = id
    var url = root.localMode() ? "http://localhost:8643" : root.bridgeUrl()
    root.fetchJson(url + "/model", function(resp) {
      root.applyingModel = ""
      root.fetchFromBridge()
    }, function() {
      root.applyingModel = ""
    }, "POST", JSON.stringify({ model: id }))
  }

  function selectCursor(index) {
    var n = root.modelRows.length
    if (n === 0) return
    root.modelCursor = ((index % n) + n) % n
  }

  function clampCursor() {
    var n = root.modelRows.length
    if (root.modelCursor >= n) root.modelCursor = Math.max(0, n - 1)
    if (root.modelCursor < 0) root.modelCursor = 0
  }

  function computeModelGroups() {
    var groups = {}
    var order = []
    for (var i = 0; i < root.models.length; i++) {
      var m = root.models[i]
      var p = String(m && m.provider || "deepseek")
      if (!groups[p]) { groups[p] = []; order.push(p) }
      groups[p].push(m)
    }
    var out = []
    for (var g = 0; g < order.length; g++) {
      var key = order[g]
      out.push({
        provider: key,
        label: root.providerName(key),
        models: groups[key],
      })
    }
    return out
  }

  function buildModelRows() {
    var rows = []
    var groups = root.modelGroups
    var cp = root.currentProvider()
    for (var g = 0; g < groups.length; g++) {
      var group = groups[g]
      var expanded = group.provider === root.expandedProvider
      rows.push({
        kind: "header",
        provider: group.provider,
        label: group.label,
        count: group.models.length,
        expanded: expanded,
        current: group.provider === cp,
        // Uniform fields — delegate always reads them, so no undefined refs.
        modelId: "", sub: "", ctx: "", selected: false,
      })
      if (expanded) {
        for (var i = 0; i < group.models.length; i++) {
          var m = group.models[i]
          rows.push({
            kind: "model",
            modelId: String(m.id || ""),
            sub: root.pricingText(m),
            ctx: root.fmtCtx(root.val(m, "context", 0)),
            selected: String(m.id || "") === root.currentModel,
            provider: group.provider,
            // Uniform fields — delegate always reads them, so no undefined refs.
            label: "", count: 0, expanded: false, current: false,
          })
        }
      }
    }
    return rows
  }

  function toggleGroup(provider) {
    root.expandedProvider = (root.expandedProvider === provider) ? "" : provider
    root.cursorActive = true
  }

  // Auto-start the local usage bridge so the widget works immediately
  // in Local mode without a separate systemd service. The bridge reads
  // Hermes' state.db and config.yaml directly, and serves /hermes.json
  // on port 8643. If the port is already taken (another instance running),
  // the bridge exits silently — the widget connects to the existing one.
  Process {
    id: bridgeProcess
    command: ["python3", root.bridgeScript]
    workingDirectory: "/"
    running: true
  }

  Timer {
    id: refreshTimer
    interval: Math.max(30, Number(root.setting("refreshIntervalSec", 300))) * 1000
    running: true
    repeat: true
    onTriggered: root.fetchFromBridge()
  }

  // Retry until the bridge is ready — keeps trying every 3s until we have
  // both usage data and (in local mode) an auth token.  No hard retry cap:
  // the timer stops itself once everything is obtained.
  Timer {
    id: startupRetry
    interval: 3000
    repeat: true
    onTriggered: {
      var haveData = root.stats && root.api && root.api.ok
      var haveToken = !root.localMode() || root.bridgeToken()
      if (!haveToken) root.fetchLocalToken()
      if (!haveData) root.fetchFromBridge()
      if (haveData && haveToken) running = false
    }
  }

  onStatsChanged: {
    var cp = root.currentProvider()
    // First data: expand the active provider's group. Later: if a switch
    // landed (current model changed), follow it into its provider group.
    // Manual expand/collapse persists across refreshes otherwise.
    if (root.expandedProvider === "")
      root.expandedProvider = cp
    else if (root.prevModel !== "" && root.prevModel !== root.currentModel && cp !== root.expandedProvider)
      root.expandedProvider = cp
    root.prevModel = root.currentModel
    root.clampCursor()
  }

  onExpandedProviderChanged: root.clampCursor()

  Component.onCompleted: {
    root.fetchFromBridge()
    if (root.localMode()) root.fetchLocalToken()
    startupRetry.start()
  }
  onOpenedChanged: {
    if (root.opened) {
      root.loadSettings()
      root.fetchFromBridge()
    }
  }
  onSettingsVisibleChanged: {
    if (root.settingsVisible) root.loadSettings()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void {
      if (root.settingsVisible) root.settingsVisible = false
      else root.toggle()
    }
    function refresh(): string { root.fetchFromBridge(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""  // glyph hidden; the logo renders via iconComponent
    iconComponent: Component {
      Item {
        anchors.fill: parent

        Image {
          id: iconImg
          anchors.centerIn: parent
          anchors.verticalCenterOffset: -1
          width: 10
          height: 10
          source: Qt.resolvedUrl("assets/hermes-icon.png")
          sourceSize: Qt.size(128, 128)
          fillMode: Image.PreserveAspectFit
          smooth: true
        }

        ColorOverlay {
          anchors.fill: iconImg
          source: iconImg
          color: root.bar ? root.bar.foreground : "#d3c6aa"
        }
      }
    }
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        root.settingsVisible = false
        root.chatActive = true
      }
      else if (buttonCode === Qt.MiddleButton) root.fetchFromBridge()
      else if (root.settingsVisible) root.settingsVisible = false
      else root.toggle()
    }
  }

  // PopupCard (xdg-popup, anchored to the bar surface) instead of KeyboardPanel
  // (layer-shell PanelWindow): KeyboardPanel reparents its window across monitor
  // bars when toggled on multi-monitor setups, tripping Qt's "Cannot use same
  // item on different windows" and segfaulting Quickshell on click. PopupCard is
  // what every stock Omarchy bar widget uses. Tradeoff: no keyboard focus prime,
  // so the keyCatcher is inert until the popup itself is clicked.
  PopupCard {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && !root.chatActive
    contentWidth: panel.fittedContentWidth(Style.space(392))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      visible: true

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) { root.cursorActive = true; root.selectCursor(root.modelCursor + dx) }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(88), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: {
        var row = root.modelRows[root.modelCursor]
        if (!row) return
        if (row.kind === "header")
          root.toggleGroup(row.provider)
        else
          root.applyModel(row.modelId)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.fetchFromBridge()
        else if (t === "q" || t === "Q") root.close()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        visible: !root.chatActive
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOff }

        Column {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: root.heroTitle()
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                width: Style.font.display
                height: Style.font.display
                Image {
                  anchors.centerIn: parent
                  width: Style.font.display
                  height: Style.font.display
                  source: root.iconSource
                  sourceSize: Qt.size(128, 128)
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                }

                // Only the logo opens the dashboard — not the whole hero bar.
                TapHandler {
                  onTapped: {
                    var u = root.providerUrl()
                    if (u && root.bar) root.bar.run("xdg-open " + u)
                  }
                }
              }
            }

            trailingControl: Component {
              Item {
                width: Style.font.title + Style.space(8)
                height: Style.font.title + Style.space(8)

                Text {
                  anchors.centerIn: parent
                  text: "☰"
                  color: root.foreground
                  font.pixelSize: Style.font.title
                }

                // TapHandler bypasses Flickable/PanelKeyCatcher event interception
                TapHandler {
                  onTapped: {
                    root.settingsVisible = !root.settingsVisible
                    // Visual feedback: brief accent pulse
                    gearAccent.start()
                  }
                }

                // Brief accent pulse to confirm the click
                PropertyAnimation {
                  id: gearAccent
                  target: parent
                  property: "opacity"
                  to: 1.0
                  duration: 100
                  onFinished: { parent.opacity = 0.6 }
                }
              }
            }
          }

          // ---------- Status / auth help ----------
          Rectangle {
            visible: root.statusText() !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: root.alpha(urgent, 0.10)
            border.width: 1
            border.color: root.alpha(urgent, 0.35)

            Text {
              id: statusText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.statusText()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Settings ----------
          // Settings moved to a separate PopupCard (below) to avoid PanelKeyCatcher
          // keyboard interception. The gear icon toggles root.settingsVisible.
          // Inline fallback kept hidden unless USE_INLINE_SETTINGS is set to true.
          Item { visible: false; width: 1; height: 1 }

          // ---------- Balance ----------
          PanelSeparator { visible: root.showBalance(); foreground: root.foreground }

          Column {
            id: balanceColumn
            visible: root.showBalance() && root.api !== null && root.api.ok
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: root.api && root.api.balanceAvailable === false
                  ? root.providerLabel() + " subscription"
                  : "Credits remaining"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                text: root.api && root.api.balanceAvailable === false
                  ? "usage-only"
                  : root.fmtMoney(root.remaining)
                color: root.api && root.api.balanceAvailable === false
                  ? root.dim
                  : (root.alarming ? urgent : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: !(root.api && root.api.balanceAvailable === false)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: root.api && root.api.balanceAvailable !== false
              width: parent.width
              value: root.ratio
              alarming: root.alarming
            }

            Text {
              width: parent.width
              text: root.api && root.api.balanceAvailable === false
                ? "estimated from Hermes usage data"
                : (root.api && root.api.ok
                  ? root.fmtMoney(root.api.used) + " spent of " + root.fmtMoney(root.funded) + " funded"
                  : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.api && root.api.balanceAvailable !== false
              text: "Whole " + root.providerLabel() + " account — includes all API keys"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              opacity: 0.8
            }
          }

          // ---------- Quick stats ----------
          PanelSeparator { visible: root.usage !== null; foreground: root.foreground }

          Row {
            id: statRow
            visible: root.usage !== null
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.usage ? [
                { title: "TODAY", tokens: root.usage.today.tokens, cost: root.cardCost("daily", root.usage.today.cost) },
                { title: "7 DAYS", tokens: root.usage.week.tokens, cost: root.cardCost("weekly", root.usage.week.cost) },
                { title: "30 DAYS", tokens: root.usage.month30.tokens, cost: root.cardCost("monthly", root.usage.month30.cost) }
              ] : []

              StatCard {
                required property var modelData
                width: (statRow.width - statRow.spacing * 2) / 3
                label: modelData.title
                tokens: modelData.tokens
                cost: modelData.cost
              }
            }
          }

          Text {
            width: parent.width
            visible: root.keyUsage !== null
            text: root.providerLabel() + " balance · usage from the bridge"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            visible: root.keyUsage === null
            text: "Consolidated local estimates · tokens from " + root.profileScope
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // ---------- Tokens by day ----------
          PanelSeparator { visible: root.showDayChart(); foreground: root.foreground }
          PanelSectionHeader {
            visible: root.showDayChart()
            width: parent.width
            text: "TOKENS BY DAY · ESTIMATED"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.usage && root.usage.byDay ? root.usage.byDay : []
            DayRow {
              visible: root.showDayChart()
              height: root.showDayChart() ? implicitHeight : 0
              required property var modelData
              width: contentColumn.width
              day: modelData
              ratio: Number(modelData.tokens || 0) / root.weekPeak()
            }
          }

          // ---------- Tokens by model (30d) ----------
          PanelSeparator { visible: root.showModelUsage(); foreground: root.foreground }
          PanelSectionHeader {
            visible: root.showModelUsage()
            width: parent.width
            text: "MODELS · 30 DAYS · ESTIMATED"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.usage && root.usage.byModel ? root.usage.byModel : []
            ModelUsageRow {
              visible: root.showModelUsage()
              height: root.showModelUsage() ? implicitHeight : 0
              required property var modelData
              width: contentColumn.width
              row: modelData
            }
          }

          // ---------- Model switcher ----------
          PanelSeparator { visible: root.showProviderAccordion(); foreground: root.foreground }
          PanelSectionHeader {
            visible: root.showProviderAccordion()
            width: parent.width
            text: "SWITCH MODEL"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

            Repeater {
              id: modelList
              model: root.modelRows

            delegate: Item {
              required property var modelData
              required property int index
              width: contentColumn.width
              visible: root.showProviderAccordion()
              height: root.showProviderAccordion()
                ? (modelData.kind === "header" ? Style.space(28) : Style.space(30)) : 0

              // Provider group header — click/Enter toggles the accordion.
              Rectangle {
                visible: modelData.kind === "header"
                anchors.fill: parent
                radius: Style.cornerRadius
                color: root.cursorActive && index === root.modelCursor
                       ? root.track : root.alpha(root.foreground, 0.05)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.toggleGroup(modelData.provider)
                }

                Row {
                  spacing: Style.space(6)
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    text: modelData.expanded ? "▾" : "▸"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Text {
                    text: modelData.label
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Text {
                    text: modelData.count
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  visible: modelData.current
                  text: "current"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              // Model row — only present inside the expanded group.
              ModelOption {
                visible: modelData.kind === "model"
                width: parent.width
                rowIndex: index
                modelId: modelData.modelId
                sub: modelData.sub
                ctx: modelData.ctx
                selected: modelData.selected
                optionCursor: root.cursorActive && index === root.modelCursor
                applying: String(modelData.modelId) === root.applyingModel
              }
            }
          }

          Text {
            width: parent.width
            visible: root.showProviderAccordion() && root.applyingModel !== ""
            text: "Switching to " + root.shortModel(root.applyingModel) + "…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            visible: root.showProviderAccordion()
            text: "Switches the Hermes agent's model through the usage bridge.\nmodel.default — new sessions use it; open sessions keep theirs."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
          }

          // ---------- Recent sessions ----------
          PanelSeparator {
            visible: root.showRecentSessions() && root.lastSessions.length > 0
            foreground: root.foreground
          }
          PanelSectionHeader {
            visible: root.showRecentSessions() && root.lastSessions.length > 0
            width: parent.width
            text: "RECENT SESSIONS · ALL PROFILES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.lastSessions
            SessionRow {
              visible: root.showRecentSessions()
              height: root.showRecentSessions() ? implicitHeight : 0
              required property var modelData
              width: contentColumn.width
              row: modelData
            }
          }

          // ---------- Footer ----------
          Text {
            width: parent.width
            topPadding: Style.space(4)
            text: "r refresh · Enter expand/apply · ←/→ switch · Esc close"
              + (root.updatedAt !== "" ? "   ·   " + root.shortTime(root.updatedAt) : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }

    }
  }

  // KeyboardPanel's built-in outside-click catcher calls owner.close(). Give
  // chat its own owner so dismissal clears chatActive instead of only closing
  // the dashboard panel underneath it.
  QtObject {
    id: chatOwner
    function close(): void { root.chatActive = false }
  }

  // Chat uses KeyboardPanel (layer-shell) for proper keyboard focus. The
  // component primes focus exclusively, then switches itself to OnDemand so
  // its built-in outside-click catcher can dismiss the panel.
  KeyboardPanel {
    id: chatPanel
    anchorItem: button
    owner: chatOwner
    bar: root.bar
    open: root.chatActive
    focusTarget: chatInput
    contentWidth: chatPanel.fittedContentWidth(Style.space(392))
    contentHeight: Style.space(660)

    // Back button header — anchored to the top.
    Item {
      id: chatHeader
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      height: Style.space(20)

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "← Chat with Hermes"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        TapHandler { onTapped: root.chatActive = false }
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        // Resume in terminal (or copy the remote session ID).
        Text {
          text: ">_"
          color: root.dim
          font.family: "monospace"
          font.pixelSize: Style.font.body
          ToolTip.visible: terminalHover.hovered
          ToolTip.text: root.localMode()
            ? "Open this conversation in a terminal"
            : "Copy session ID to clipboard"
          HoverHandler { id: terminalHover }
          TapHandler {
            onTapped: {
              var url = root.localMode() ? "http://localhost:8643" : root.bridgeUrl()
              root.fetchJson(url + "/session", function(resp) {
                var raw = resp.session_id || ""
                var sid = root.safeSessionId(raw)
                if (!sid || sid !== raw) return  // reject malformed session ids
                if (root.localMode()) {
                  if (root.bar) root.bar.run("xdg-terminal-exec hermes chat --resume " + sid)
                } else {
                  if (root.bar) root.bar.run("wl-copy " + sid)
                  root.chatBusy = false
                }
              }, function() {}, "GET")
            }
          }
        }

        // New session.
        Text {
          text: "✎"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          ToolTip.visible: newSessionHover.hovered
          ToolTip.text: "New chat session"
          HoverHandler { id: newSessionHover }
          TapHandler {
            onTapped: {
              var url = root.localMode() ? "http://localhost:8643" : root.bridgeUrl()
              root.chatMessages = []
              root.fetchJson(url + "/chat/new", function(resp) {}, function() {}, "POST", "{}")
            }
          }
        }
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.max(1, Style.space(2))
        radius: height / 2
        color: root.accent
        opacity: 0.75
      }
    }

    PanelSeparator {
      id: chatSeparator
      anchors.top: chatHeader.bottom
      anchors.topMargin: Style.space(8)
      anchors.left: parent.left
      anchors.right: parent.right
      foreground: root.foreground
    }

    // Message log fills all space between the header and input bar.
    ScrollView {
      id: chatScroll
      anchors.top: chatSeparator.bottom
      anchors.topMargin: Style.space(8)
      anchors.bottom: chatInputRow.top
      anchors.bottomMargin: Style.space(8)
      anchors.left: parent.left
      anchors.right: parent.right
      clip: true
      ScrollBar.vertical.policy: ScrollBar.AlwaysOff

      Column {
        width: chatScroll.width
        spacing: Style.space(8)

        Repeater {
          model: root.chatMessages
          delegate: Text {
            required property var modelData
            width: parent.width
            wrapMode: Text.WordWrap
            text: (modelData.role === "user" ? "You: " : "Hermes: ") + modelData.text
            color: modelData.role === "user" ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          visible: root.chatBusy
          text: "Hermes is thinking…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // Input bar — pinned to the bottom, independent of content height.
    Rectangle {
      id: chatInputRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(34)
      color: root.alpha(root.foreground, 0.06)
      border.width: 1
      border.color: root.alpha(root.foreground, 0.22)
      radius: Style.cornerRadius

      TextInput {
        id: chatInput
        anchors.left: parent.left
        anchors.right: chatSendBtn.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(4)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        activeFocusOnPress: true
        enabled: !root.chatBusy
        clip: true
        Keys.onEscapePressed: root.chatActive = false
        onAccepted: {
          root.sendChatMessage(text)
          text = ""
        }
      }

      Text {
        anchors.left: chatInput.left
        anchors.verticalCenter: chatInput.verticalCenter
        visible: !chatInput.text && !chatInput.activeFocus
        text: "Type a message…"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: chatSendBtn
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: "→"
        color: root.chatBusy ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        TapHandler {
          onTapped: {
            root.sendChatMessage(chatInput.text)
            chatInput.text = ""
          }
        }
      }
    }
  }

  // Settings use KeyboardPanel rather than PopupCard: xdg-popup surfaces are
  // intentionally non-focusable, so a TextInput inside PopupCard can never
  // receive compositor keyboard focus. KeyboardPanel provides the normal
  // layer-shell focus prime while keeping this editor separate from the
  // data panel's PanelKeyCatcher.
  KeyboardPanel {
    id: settingsPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.settingsVisible
    focusTarget: bridgeUrlInput
    contentWidth: settingsPanel.fittedContentWidth(Style.space(392))
    contentHeight: settingsPanel.fittedContentHeight(settingsPopupColumn.implicitHeight, Style.space(560))

    // No Flickable — settings content fits. Flickable intercepts press events
    // which prevents TextInput from receiving clicks for cursor positioning.
    Column {
      id: settingsPopupColumn
      width: parent.width
      spacing: Style.space(12)

        // A compact close affordance and accent rule visually tie this
        // keyboard surface to the gear without turning settings into a
        // separate navigation page.
        Item {
          width: parent.width
          height: Style.space(20)

          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: "✕"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall

            TapHandler { onTapped: root.settingsVisible = false }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.max(1, Style.space(2))
            radius: height / 2
            color: root.accent
            opacity: 0.75
          }
        }

        PanelSeparator { foreground: root.foreground }

        // CONNECTION
        PanelSectionHeader {
          width: parent.width
          text: "CONNECTION"
          foreground: root.dim
          fontFamily: root.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(12)
          leftPadding: Style.space(8)

          Text {
            text: (root.localMode() ? "●" : "○") + " Local"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            TapHandler {
              onTapped: {
                root.saveSettings({ connectionMode: "local", bridgeUrl: "http://localhost:8643" })
              }
            }
          }

          Text {
            text: (!root.localMode() ? "●" : "○") + " Remote"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            TapHandler {
              onTapped: {
                var current = root.bridgeUrl()
                var fallback = "http://localhost:8643"
                var url = current === "http://your-hermes:8643" ? fallback : current
                root.saveSettings({ connectionMode: "remote", bridgeUrl: url })
              }
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          leftPadding: Style.space(8)
          visible: !root.localMode()

          Text {
            text: "Access token"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            verticalAlignment: Text.AlignVCenter
          }

          Rectangle {
            width: parent.width - Style.space(92)
            height: Style.space(28)
            color: root.alpha(root.foreground, 0.08)
            border.width: 1
            border.color: root.alpha(root.foreground, 0.30)
            radius: Style.cornerRadius

            TextInput {
              id: bridgeTokenInput
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              text: String(root.settingValue("remoteToken", "") || "")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              echoMode: TextInput.Password
              selectByMouse: true
              activeFocusOnPress: true
              activeFocusOnTab: true
              onEditingFinished: root.saveSetting("remoteToken", text)
              TapHandler { onTapped: parent.forceActiveFocus() }
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          leftPadding: Style.space(8)

          Text {
            text: "Bridge URL"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            verticalAlignment: Text.AlignVCenter
          }

          Rectangle {
            width: parent.width - Style.space(92)
            height: Style.space(28)
            color: root.alpha(root.foreground, root.localMode() ? 0.04 : 0.08)
            border.width: 1
            border.color: root.alpha(root.foreground, root.localMode() ? 0.10 : 0.30)
            radius: Style.cornerRadius

            TextInput {
              id: bridgeUrlInput
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              text: root.bridgeUrl()
              color: root.localMode() ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              readOnly: root.localMode()
              selectByMouse: true
              cursorVisible: !root.localMode()
              activeFocusOnPress: true
              activeFocusOnTab: true
              onActiveFocusChanged: {
                if (activeFocus) Qt.inputMethod.show()
                else Qt.inputMethod.hide()
              }
              verticalAlignment: TextInput.AlignVCenter
              onEditingFinished: {
                if (!root.localMode() && text !== "") root.saveSetting("bridgeUrl", text)
              }
              TapHandler {
                onTapped: {
                  if (!root.localMode()) {
                    parent.forceActiveFocus()
                    parent.cursorVisible = true
                  }
                }
              }
            }
          }
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          text: "Status: Connected · " + root.heroMeta()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { foreground: root.foreground }

        // VISIBILITY
        PanelSectionHeader {
          width: parent.width
          text: "VISIBILITY"
          foreground: root.dim
          fontFamily: root.fontFamily
        }

        Repeater {
          model: [
            { key: "balanceVisible", label: "Balance card" },
            { key: "tokensByDayVisible", label: "Tokens by day chart" },
            { key: "modelUsageVisible", label: "Model usage (30d)" },
            { key: "providerAccordionVisible", label: "Provider accordion" },
            { key: "recentSessionsVisible", label: "Recent sessions" }
          ]
          delegate: Text {
            required property var modelData
            width: parent.width
            leftPadding: Style.space(8)
            text: root.settingBool(modelData.key, true) ? "☑ " + modelData.label : "☐ " + modelData.label
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            TapHandler {
              onTapped: root.saveSetting(modelData.key, !root.settingBool(modelData.key, true))
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ABOUT
        PanelSectionHeader {
          width: parent.width
          text: "ABOUT"
          foreground: root.dim
          fontFamily: root.fontFamily
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          text: "hermes-agent-widget v1.1.0"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          text: "github.com/r3pc0n/hermes-agent-widget"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Item { width: 1; height: Style.space(4) }
      }
  }

  // ------------------------------------------------------------ components

  // Small stat card: label over tokens + cost.
  component StatCard: Item {
    id: card
    property string label: ""
    property real tokens: 0
    property real cost: 0

    implicitHeight: cardTitle.implicitHeight + cardBody.implicitHeight + Style.space(2)

    Text {
      id: cardTitle
      anchors.left: parent.left
      anchors.top: parent.top
      text: card.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      id: cardBody
      anchors.left: parent.left
      anchors.top: cardTitle.bottom
      anchors.topMargin: Style.space(2)
      text: root.fmtTokens(card.tokens) + "  " + root.fmtMoney(card.cost)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  // Rounded meter showing the used fraction of the topped-up balance.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meter.value >= 0 ? meterTrack.height : 0
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  // One row per day: weekday, bar, token count, spend. The bar runs
  // between the weekday label and the token count, and the spend column
  // lines up with the MODELS section's cost column.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0

    readonly property bool today: String(dayRow.day ? dayRow.day.date : "") === root.todayDate()

    implicitHeight: Math.max(dayLabelText.implicitHeight,
                             Math.max(dayValue.implicitHeight, dayCost.implicitHeight))
                   + Style.space(2)

    Text {
      id: dayLabelText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "")
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Text {
      id: dayCost
      text: root.fmtMoney(dayRow.day ? dayRow.day.cost : 0)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(64)
    }

    Text {
      id: dayValue
      text: root.fmtTokens(dayRow.day ? dayRow.day.tokens : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      horizontalAlignment: Text.AlignRight
      anchors.right: dayCost.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabelText.right
      anchors.leftMargin: Style.space(8)
      anchors.right: dayValue.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: root.alpha(root.foreground, 0.6)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }
  }

  // One model row: name, tokens, estimated spend.
  component ModelUsageRow: Item {
    id: modelRow
    property var row: null

    implicitHeight: modelName.implicitHeight + Style.space(8)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Text {
      id: modelName
      text: row && row.model ? root.modelDisplay(String(row.model)) : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      text: row ? root.fmtTokens(row.tokens) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      anchors.right: modelCost.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelCost
      text: row ? root.fmtMoney(row.cost) : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // One model selector row: id, context, per-1M price; click switches.
  component ModelOption: Item {
    id: option
    property int rowIndex: -1
    property string modelId: ""
    property string sub: ""
    property string ctx: ""
    property bool selected: false
    property bool optionCursor: false
    property bool applying: false

    implicitHeight: Style.space(30)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: option.optionCursor ? root.track : root.alpha(root.foreground, option.selected ? 0.16 : 0.05)

      Behavior on color {
        ColorAnimation { duration: 120 }
      }
    }

    Text {
      id: optionId
      // Group header already names the provider — bare short id here.
      text: option.modelId === "" ? "—" : root.shortModel(option.modelId)
      color: option.applying ? root.dim : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: option.selected
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: optionContext.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: optionContext
      text: option.ctx
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: optionPrice.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: optionPrice
      text: option.sub
      color: option.selected ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: optionCheck.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: optionCheck
      text: option.applying ? "⟳" : (option.selected ? "✓" : " ")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: {
        root.cursorActive = true
        root.modelCursor = option.rowIndex
        root.applyModel(option.modelId)
      }
    }
  }

  // One recent session row: title, model, start time, cost.
  component SessionRow: Item {
    id: sessionRow
    property var row: null

    implicitHeight: sessionTitle.implicitHeight + Style.space(2)

    Text {
      id: sessionTitle
      text: row ? "[" + String(row.profile || "default") + "] " + row.title : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.right: sessionTime.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: sessionTime
      text: row ? row.started : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: sessionCost.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: sessionCost
      text: row ? root.fmtMoney(row.cost) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
