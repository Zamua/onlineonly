PREFIX ?= /usr/local
CC ?= clang
CFLAGS ?= -O2
CFLAGS += -fobjc-arc -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=11.0
LDFLAGS += -framework Foundation

LIB = src/OODomain.m src/OODropbox.m src/OOResult.m src/OOService.m src/OOMCP.m
HDR = $(wildcard src/*.h)

onlineonly: $(LIB) src/main.m $(HDR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(LIB) src/main.m

build/tests: $(LIB) tests/tests.m $(HDR)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(LIB) tests/tests.m

test: build/tests onlineonly
	./build/tests
	./tests/mcp_stdio.sh ./onlineonly

install: onlineonly
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 onlineonly $(DESTDIR)$(PREFIX)/bin/onlineonly

clean:
	rm -rf onlineonly build

.PHONY: test install clean
