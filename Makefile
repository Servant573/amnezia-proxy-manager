PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec
DATADIR ?= $(PREFIX)/share
DESTDIR ?=
export PREFIX BINDIR LIBEXECDIR DATADIR DESTDIR

.PHONY: install uninstall
install:
	python3 scripts/install.py install

uninstall:
	python3 scripts/install.py uninstall
