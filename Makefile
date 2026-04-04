.PHONY: all package clean

all: package

package:
	@chmod +x package_macos.sh
	./package_macos.sh

clean:
	rm -rf build/
	rm -f Farkle.dmg
	rm -rf dmg_staging/
