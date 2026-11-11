import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

RowLayout {
  id: root
  required property var host
  required property string area
  readonly property bool fatal: area === "global" && host.stateError !== ""
  visible: fatal || (host.noticeContext === area && (host.noticeKey !== "" || host.operationError !== ""))
  spacing: Style.space(6)

  ColumnLayout {
    Layout.fillWidth: true
    spacing: Style.space(3)
    Text {
      Layout.fillWidth: true
      visible: root.fatal || root.host.noticeKey !== ""
      textFormat: Text.PlainText
      text: root.fatal ? root.host.translations.t("errors." + root.host.stateError)
        : root.host.translations.t("messages." + root.host.noticeKey)
      color: root.fatal || root.host.noticeIsError ? "#ff7777" : root.host.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
    }
    Text {
      Layout.fillWidth: true
      visible: root.host.operationError !== ""
      textFormat: Text.PlainText
      text: root.host.operationError
      color: "#ff7777"
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
    }
  }
  Button {
    text: root.host.translations.t("common.dismiss")
    visible: !root.fatal && !root.host.libraryBusy
    focusable: true
    onClicked: {
      root.host.noticeKey = ""
      root.host.operationError = ""
    }
  }
}
