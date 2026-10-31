PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec
DATADIR ?= $(PREFIX)/share
DESTDIR ?=
DISTDIR ?= dist
SOURCE_DATE_EPOCH ?= 0
export DISTDIR SOURCE_DATE_EPOCH
export PREFIX BINDIR LIBEXECDIR DATADIR DESTDIR

.PHONY: install uninstall dist check-dist
install:
	python3 scripts/install.py install

uninstall:
	python3 scripts/install.py uninstall

dist:
	python3 scripts/release.py

check-dist:
	python3 tests/release.py
