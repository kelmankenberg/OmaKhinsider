OMARCHY_PATH ?= /usr/share/omarchy

.PHONY: validate test

validate:
	omarchy plugin validate .
	qmllint -I "$(OMARCHY_PATH)/shell" BarWidget.qml Panel.qml

test:
	QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 qmltestrunner -input tests
