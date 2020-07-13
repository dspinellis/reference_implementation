VERSION=$(shell sed -n 's/\s.*version="\(.*\)",/\1/p' setup.py)
DEB=../epidose_$(VERSION)_armhf.deb
OPT=/opt/venvs/epidose
SITE=$(OPT)/lib/python3.7/site-packages

package:
	rm -rf debian
	# Create a Debian package structure
	make-deb
	# Correct the resulting rules file
	# See https://github.com/nylas/make-deb/issues/23
	printf '\n\noverride_dh_virtualenv:\n\tdh_virtualenv --use-system-packages\n' >>debian/rules
	# Package the Debian package structure into an installable .deb file
	dpkg-buildpackage --build=binary --unsigned-source --unsigned-changes

install: $(DEB)
	-apt-get -y remove epidose
	rm -rf /opt/venvs/epidose
	dpkg -i $(DEB)
	mkdir -p /var/lib/epidose
	cp epidose/device/supervisord.conf /etc/supervisor/conf.d/epidose.conf
	systemctl reload supervisor

# Install after source code files have changed
fast-install:
	cp -r epidose dp3t $(SITE)/
	cp epidose/device/upload_seeds_d.sh \
		epidose/device/update_filter_d.sh \
		epidose/device/util.sh $(OPT)/bin/
	supervisorctl restart epidose:*
