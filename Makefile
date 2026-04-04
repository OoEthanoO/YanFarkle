.PHONY: all package clean

all: package

package: clean
	@chmod +x package_macos.sh
	./package_macos.sh

clean:
	rm -rf build/
	rm -f *.dmg
	rm -rf dmg_staging/
