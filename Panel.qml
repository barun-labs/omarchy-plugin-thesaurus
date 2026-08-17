import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Dictionary + thesaurus lookup panel. Opens pre-filled with the highlighted
// word (lookup.sh reads it via wl-paste); the field is editable and Enter
// re-runs the lookup. All lookup logic lives in lookup.sh — this panel only
// runs it and renders the one JSON object it prints.
Panel {
  id: root
  moduleName: "barun-labs.thesaurus"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property string word: ""
  property string definition: ""
  property string example: ""
  property var synonyms: []
  property var antonyms: []
  property var suggestions: []
  property string errorKind: ""
  property bool loading: false

  property string llmOutput: ""
  property string llmError: ""
  property bool llmLoading: false

  // lookup.sh's absolute path. Qt.resolvedUrl gives a file:// URL; Process
  // needs a plain filesystem path.
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("lookup.sh"))
    return decodeURIComponent(url.indexOf("file://") === 0 ? url.substring(7) : url)
  }

  readonly property string llmHelperPath: {
    var url = String(Qt.resolvedUrl("llm.sh"))
    return decodeURIComponent(url.indexOf("file://") === 0 ? url.substring(7) : url)
  }

  // Always open to an empty field so the user types the word they want. The
  // highlighted selection is deliberately ignored — it kept prefilling URLs.
  function open() {
    root.controller.show()
    root.clearResult()
    queryField.text = ""
    queryField.prefilled = false
  }

  function clearResult() {
    root.word = ""
    root.definition = ""
    root.example = ""
    root.synonyms = []
    root.antonyms = []
    root.suggestions = []
    root.errorKind = ""
    root.loading = false
    root.llmOutput = ""
    root.llmError = ""
    root.llmLoading = false
  }

  // Optional highlight-lookup: open and immediately look up the highlighted
  // word (lookup.sh reads the selection). Bound to right-click / an IPC verb,
  // so the default left-click stays empty.
  function openWithSelection() {
    root.controller.show()
    root.clearResult()
    queryField.text = ""
    queryField.prefilled = false
    runLookup([])            // no arg -> lookup.sh reads the highlighted word
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }
  // Toggle variant for the keybind: open looks up the highlighted word,
  // second press closes. Left-click's plain toggle() stays empty-field.
  function toggleSelection() { root.opened ? root.close() : root.openWithSelection() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function lookupWord(text) {
    var w = String(text || "").trim()
    if (w === "") return
    queryField.text = w
    runLookup([w])
  }

  function runLookup(extraArgs) {
    if (lookupProcess.running) return
    root.loading = true
    root.errorKind = ""
    lookupProcess.command = ["bash", root.helperPath].concat(extraArgs)
    lookupProcess.running = true
  }

  function applyResult(raw) {
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
    if (!parsed) { root.errorKind = "offline"; return }
    root.word = String(parsed.word || "")
    root.definition = String(parsed.definition || "")
    root.example = String(parsed.example || "")
    root.synonyms = parsed.synonyms || []
    root.antonyms = parsed.antonyms || []
    root.suggestions = parsed.suggestions || []
    root.errorKind = parsed.error ? String(parsed.error) : ""
    // Show the looked-up word in the field, unless the user is mid-typing a
    // different one (empty field = selection lookup, safe to fill). Mark it
    // prefilled so the next keystroke replaces the word instead of appending.
    if (root.word !== "" && (queryField.text === "" || !queryField.activeFocus)) {
      queryField.text = root.word
      queryField.prefilled = true
    }
  }

  Process {
    id: lookupProcess
    stdout: StdioCollector {
      id: lookupStdout
      waitForEnd: true
      onStreamFinished: root.applyResult(text)
    }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0 && root.errorKind === "") root.errorKind = "offline"
    }
  }

  function runLlm(mode, kind) {
    if (llmProcess.running || lookupProcess.running) return
    root.llmLoading = true
    root.llmError = ""
    root.llmOutput = ""
    var args = [root.llmHelperPath, "--mode", mode]
    if (kind && kind !== "") args = args.concat(["--kind", kind])
    if (root.word !== "") args = args.concat([root.word])
    llmProcess.command = ["bash"].concat(args)
    llmProcess.running = true
  }

  function applyLlm(raw) {
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
    if (!parsed) { root.llmError = "offline"; return }
    root.llmError = parsed.error ? String(parsed.error) : ""
    root.llmOutput = root.llmError === "" ? String(parsed.output || "") : ""
  }

  Process {
    id: llmProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyLlm(text)
    }
    onExited: function(exitCode) {
      root.llmLoading = false
      if (exitCode !== 0 && root.llmError === "" && root.llmOutput === "")
        root.llmError = "offline"
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: queryField
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        TextField {
          id: queryField
          width: parent.width
          placeholderText: "Look up a word…"
          foreground: root.contentForeground
          font.family: root.contentFontFamily

          // True when the field holds a looked-up word we filled in, not text
          // the user typed. The first printable key then replaces it wholesale.
          property bool prefilled: false

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.lookupWord(queryField.text)
              event.accepted = true
              return
            }
            if (event.key === Qt.Key_Escape) {
              root.close()
              event.accepted = true
              return
            }
            if (queryField.prefilled) {
              queryField.prefilled = false
              // Printable key (>= space): drop the looked-up word so the char
              // starts a fresh query. Navigation/backspace fall through as edits.
              if (event.text.length > 0 && event.text.charCodeAt(0) >= 0x20)
                queryField.text = ""
            }
          }
        }

        Row {
          visible: root.word !== "" || queryField.text !== ""
          width: parent.width
          spacing: Style.space(14)

          // Reuse this inline for Define / Explain. Transform added in Task 4.
          Text {
            text: "Define"
            color: defMouse.containsMouse ? Color.accent : root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            MouseArea { id: defMouse; anchors.fill: parent; hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.lookupWord(queryField.text !== "" ? queryField.text : root.word) }
          }
          Text {
            text: "Explain"
            color: expMouse.containsMouse ? Color.accent : root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            MouseArea { id: expMouse; anchors.fill: parent; hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.runLlm("explain", "") }
          }
        }

        // Status line for the loading / empty / offline paths.
        Text {
          visible: root.loading || root.errorKind !== "" || root.word === ""
          width: parent.width
          text: root.loading ? "Looking up…"
            : root.errorKind === "offline" ? "Offline — no lookup"
            : root.word === "" ? "Type a word, then press Enter"
            : ""
          color: Util.alpha(root.contentForeground, 0.64)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Result card. Shown once a word resolves without error.
        Column {
          visible: root.errorKind === "" && !root.loading && root.word !== ""
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: root.word
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            visible: root.definition !== ""
            width: parent.width
            text: root.definition
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.example !== ""
            width: parent.width
            text: "“" + root.example + "”"
            color: Util.alpha(root.contentForeground, 0.64)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.italic: true
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.definition === ""
            width: parent.width
            text: "No definition found."
            color: Util.alpha(root.contentForeground, 0.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          // "Did you mean" — spelling suggestions when the word wasn't found.
          Column {
            visible: root.definition === "" && root.synonyms.length === 0
                     && root.antonyms.length === 0 && root.suggestions.length > 0
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "Did you mean"
              color: Util.alpha(root.contentForeground, 0.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Flow {
              width: parent.width
              spacing: Style.space(10)
              Repeater {
                model: root.suggestions
                Text {
                  required property var modelData
                  text: modelData
                  color: sugMouse.containsMouse ? Color.accent : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.underline: sugMouse.containsMouse
                  MouseArea {
                    id: sugMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.lookupWord(modelData)
                  }
                }
              }
            }
          }

          PanelSeparator {
            visible: root.synonyms.length > 0 || root.antonyms.length > 0
            width: parent.width
          }

          Repeater {
            model: [
              { label: "SYN", terms: root.synonyms },
              { label: "ANT", terms: root.antonyms }
            ]
            Row {
              required property var modelData
              visible: modelData.terms.length > 0
              width: content.width
              spacing: Style.space(8)
              Text {
                width: Style.space(34)
                text: modelData.label
                color: Util.alpha(root.contentForeground, 0.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Text {
                width: content.width - Style.space(34) - Style.space(8)
                text: modelData.terms.join(", ")
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        // LLM "Thinking…" line.
        Text {
          visible: root.llmLoading
          width: parent.width
          text: "Thinking…"
          color: Util.alpha(root.contentForeground, 0.64)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        // LLM error line (distinct messages per kind).
        Text {
          visible: !root.llmLoading && root.llmError !== ""
          width: parent.width
          text: root.llmError === "no-key"
              ? "Add a DeepSeek key to enable Explain (see README)."
            : root.llmError === "rate-limit" ? "Rate limited — try again shortly."
            : root.llmError === "timeout" ? "Timed out — try again."
            : "Offline — Explain unavailable."
          color: Util.alpha(root.contentForeground, 0.64)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // LLM output card.
        Column {
          visible: !root.llmLoading && root.llmError === "" && root.llmOutput !== ""
          width: parent.width
          spacing: Style.space(4)
          Text {
            width: parent.width
            text: root.llmOutput
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
          Text {
            text: "via DeepSeek"
            color: Util.alpha(root.contentForeground, 0.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
