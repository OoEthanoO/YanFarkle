.PHONY: all package clean

all: package

package: clean
	@chmod +x package_macos.sh
	./package_macos.sh

clean:
	rm -rf build/
	rm -f YanFarkle*.dmg
	rm -rf dmg_staging/
