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
  property string errorKind: ""
  property bool loading: false

  // lookup.sh's absolute path. Qt.resolvedUrl gives a file:// URL; Process
  // needs a plain filesystem path.
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("lookup.sh"))
    return decodeURIComponent(url.indexOf("file://") === 0 ? url.substring(7) : url)
  }

  function open() {
    root.controller.show()
    runLookup([])            // no arg -> lookup.sh reads the highlighted word
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function lookupWord(text) {
    var w = String(text || "").trim()
    if (w === "") return
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
    root.errorKind = parsed.error ? String(parsed.error) : ""
    // Keep the field showing the looked-up word, unless the user is mid-typing.
    if (!queryField.activeFocus && root.word !== "") queryField.text = root.word
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
          text: root.word
          foreground: root.contentForeground
          font.family: root.contentFontFamily
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.lookupWord(queryField.text)
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              root.close()
              event.accepted = true
            }
          }
        }

        // Status line for the loading / empty / offline paths.
        Text {
          visible: root.loading || root.errorKind !== ""
          width: parent.width
          text: root.loading ? "Looking up…"
            : root.errorKind === "offline" ? "Offline — no lookup"
            : root.errorKind === "empty" ? "Highlight a word, or type one above"
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
      }
    }
  }
}
