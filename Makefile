OMARCHY_PATH ?= /usr/share/omarchy

.PHONY: validate test

validate:
	omarchy plugin validate .
	qmllint -I "$(OMARCHY_PATH)/shell" BarWidget.qml Panel.qml AudioPlayer.qml PlayerStrip.qml StatusBanner.qml BrowserSetup.qml BarPlayer.qml

test:
	QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 /usr/lib/qt6/bin/qmltestrunner -input tests/tst_model.qml
	python3 -m unittest discover -s browser-companion/tests
	python3 -m unittest discover -s tests -p 'test_*.py'
	node --test browser-companion/tests/*.test.cjs
