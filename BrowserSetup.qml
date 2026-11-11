import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

ColumnLayout {
  id: guide
  required property var host
  required property string pluginDirectory
  property string browser: "chromium"
  property alias extensionId: extensionIdField.text
  readonly property bool validExtensionId: /^[a-p]{32}$/.test(extensionId.trim())
  readonly property bool editing: extensionIdField.activeFocus || buildCommands.editing ||
    folderPath.editing || registrationCommands.editing
  readonly property string changeDirectoryCommand: "cd -- '" + pluginDirectory.replace(/'/g, "'\"'\"'") + "'"
  readonly property string buildCommand: changeDirectoryCommand +
    "\n./browser-companion/build-extension.sh " + browser
  readonly property string extensionDirectory: pluginDirectory + "/browser-companion/build/" + browser
  readonly property string registrationCommand: browser === "firefox"
    ? changeDirectoryCommand + "\n./browser-companion/install-native-host.sh firefox"
    : validExtensionId ? changeDirectoryCommand +
      "\n./browser-companion/install-native-host.sh chromium " + extensionId.trim() : ""
  signal backRequested()
  spacing: Style.space(10)

  component Paragraph: Text {
    Layout.fillWidth: true
    textFormat: Text.PlainText
    color: guide.host.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
  }

  component Heading: Paragraph {
    color: guide.host.foreground
    font.pixelSize: Style.font.body
    font.bold: true
  }

  component Commands: Rectangle {
    id: box
    required property string command
    readonly property bool editing: commandText.activeFocus
    Layout.fillWidth: true
    implicitHeight: commandLayout.implicitHeight + Style.space(16)
    color: Qt.darker(guide.host.background, 1.05)
    border.color: guide.host.border
    border.width: 1
    radius: Style.cornerRadius
    ColumnLayout {
      id: commandLayout
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(6)
      TextEdit {
        id: commandText
        Layout.fillWidth: true
        text: box.command
        textFormat: TextEdit.PlainText
        readOnly: true
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        color: guide.host.foreground
        selectionColor: Style.selectionFillFor(guide.host.foreground, guide.host.foreground)
        selectedTextColor: guide.host.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Button {
        text: guide.host.translations.t("setup.copy")
        focusable: true
        onClicked: {
          commandText.selectAll()
          commandText.copy()
          commandText.deselect()
        }
      }
    }
  }

  RowLayout {
    Layout.fillWidth: true
    Button {
      objectName: "browserSetupBack"
      text: guide.host.translations.t("setup.back")
      focusable: true
      onClicked: guide.backRequested()
    }
    Item { Layout.fillWidth: true }
  }
  Heading {
    text: guide.host.translations.t("setup.title")
    font.pixelSize: Style.font.subtitle
  }
  Paragraph { text: guide.host.translations.t("setup.intro") }
  Paragraph { text: guide.host.translations.t("setup.prerequisites") }
  RowLayout {
    Button {
      objectName: "setupChromium"
      text: "Chromium"
      active: guide.browser === "chromium"
      focusable: true
      onClicked: guide.browser = "chromium"
    }
    Button {
      objectName: "setupFirefox"
      text: "Firefox"
      active: guide.browser === "firefox"
      focusable: true
      onClicked: guide.browser = "firefox"
    }
  }
  Paragraph {
    visible: guide.browser === "firefox"
    text: guide.host.translations.t("setup.firefox_temporary")
    color: guide.host.foreground
  }
  Heading { text: guide.host.translations.t("setup.build_heading") }
  Paragraph { text: guide.host.translations.t("setup.build_help") }
  Commands {
    id: buildCommands
    objectName: "setupBuildCommands"
    command: guide.buildCommand
  }
  Heading { text: guide.host.translations.t("setup.load_heading") }
  Paragraph {
    text: guide.host.translations.t(guide.browser === "firefox" ? "setup.load_firefox" : "setup.load_chromium")
  }
  Commands {
    id: folderPath
    objectName: "setupExtensionFolder"
    command: guide.extensionDirectory
  }
  Heading { text: guide.host.translations.t("setup.register_heading") }
  Paragraph {
    text: guide.host.translations.t(guide.browser === "firefox" ? "setup.register_firefox" : "setup.register_chromium")
  }
  TextField {
    id: extensionIdField
    objectName: "setupExtensionId"
    visible: guide.browser === "chromium"
    Layout.fillWidth: true
    placeholderText: guide.host.translations.t("setup.extension_id")
    selectByMouse: true
    maximumLength: 64
  }
  Paragraph {
    visible: guide.browser === "chromium" && extensionIdField.text.length > 0 && !guide.validExtensionId
    text: guide.host.translations.t("setup.extension_id_invalid")
    color: "#ff7777"
  }
  Commands {
    id: registrationCommands
    objectName: "setupRegistrationCommands"
    visible: guide.registrationCommand !== ""
    command: guide.registrationCommand
  }
  Heading { text: guide.host.translations.t("setup.verify_heading") }
  Paragraph { text: guide.host.translations.t("setup.verify_help") }
  Heading { text: guide.host.translations.t("setup.inspect_heading") }
  Paragraph { text: guide.host.translations.t("setup.inspect_help") }
  Heading { text: guide.host.translations.t("setup.troubleshoot_heading") }
  Paragraph { text: guide.host.translations.t("setup.troubleshoot_host") }
  Paragraph { text: guide.host.translations.t("setup.troubleshoot_plugin") }
  Paragraph { text: guide.host.translations.t("setup.troubleshoot_site") }
  Heading { text: guide.host.translations.t("setup.update_heading") }
  Paragraph { text: guide.host.translations.t("setup.update_help") }
  Heading { text: guide.host.translations.t("setup.remove_heading") }
  Paragraph { text: guide.host.translations.t("setup.remove_help") }
  Button {
    objectName: "browserSetupBackBottom"
    text: guide.host.translations.t("setup.back")
    focusable: true
    onClicked: guide.backRequested()
  }
}
