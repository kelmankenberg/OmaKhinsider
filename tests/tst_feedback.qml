import QtQuick
import QtTest
import "Plugin" as Plugin

Item {
  Plugin.Panel { id: panel }

  TestCase {
    name: "OmaKhinsiderFeedback"
    when: panel.stateReady

    function test_feedbackBrowserSuccessFailureAndRetry() {
      try {
        panel.showSettings()
        for (var i = 0; i < panel.data.length; i++) {
          if (typeof panel.data[i].ensureContent === "function")
            panel.data[i].ensureContent()
        }
        var button = null
        tryVerify(function() {
          button = findChild(panel, "settingsFeedback")
          return button !== null
        })
        panel.operationError = "Previous settings error"
        button.clicked()
        tryCompare(button, "enabled", false)
        tryCompare(panel, "noticeKey", "support_opened")
        compare(panel.noticeContext, "settings")
        compare(panel.operationError, "")
        verify(!panel.noticeIsError)

        button.clicked()
        tryCompare(panel, "noticeKey", "support_open_failed")
        compare(panel.noticeContext, "settings")
        verify(panel.noticeIsError)
        verify(button.enabled)

        button.clicked()
        tryCompare(panel, "noticeKey", "support_opened")
        verify(!panel.noticeIsError)

        panel.activeTab = "albums"
        panel.openKhinsider()
        tryCompare(panel, "noticeKey", "browser_open_failed")
        compare(panel.noticeContext, "albums")
        console.log("FEEDBACK_UI_PASS")
      } finally {
        panel.close()
        Qt.quit()
      }
    }
  }
}
