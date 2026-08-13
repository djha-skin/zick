# zick.spec — RPM spec for zick, the Common Lisp package manager.
#
# Consumed by the Fedora legs of the release workflow to produce the source
# RPM (rpmbuild -bs) submitted to COPR, and by the RHEL source-rpm artifact.
# The combined source tarball (zick-<ver>-src.tar.gz, see
# scripts/make-source-tarball.sh) bundles zick plus the sibling systems
# cliff/nrdl/svers so the build is self-contained.

Name:           zick
Version:        0.1.0
Release:        1%{?dist}
Summary:        A zip-based package manager for Common Lisp systems

License:        MIT
URL:            https://github.com/djha-skin/zick
Source0:        %{url}/releases/download/v%{version}/zick-%{version}-src.tar.gz

BuildRequires:  sbcl
BuildRequires:  git
BuildRequires:  curl
BuildRequires:  make

%description
zick is a package manager for Common Lisp that resolves and installs
systems from zip archives. It tracks installed packages, their files,
and their dependencies in a local database, mirroring the behavior of
the zic package manager. zick pairs well with dsolv, the Common Lisp
resolver: dsolv tells you what to install, zick installs it.

%prep
%setup -q -n zick

%build
# Fetch the ocicl dependency manager (the distro has no ocicl package).
export OCICL_VERSION=2.17.0
curl -fSsL -o /tmp/ocicl.tgz \
    https://github.com/ocicl/ocicl/releases/download/v${OCICL_VERSION}/ocicl-${OCICL_VERSION}-linux-amd64.tar.gz
tar xzf /tmp/ocicl.tgz -C /tmp
mv /tmp/ocicl /usr/local/bin/ocicl
chmod +x /usr/local/bin/ocicl

# Make the bundled sibling systems visible to ASDF.
mkdir -p "$HOME/common-lisp"
cp -r ../cliff ../nrdl ../svers "$HOME/common-lisp/"

ocicl setup
ocicl install
sbcl --dynamic-space-size 4096 --control-stack-size 32 \
     --non-interactive --load scripts/ci-build.lisp

%install
install -Dm755 zick %{buildroot}%{_bindir}/zick

%check
cd "$(mktemp -d)"
%{buildroot}%{_bindir}/zick init
%{buildroot}%{_bindir}/zick list

%files
%{_bindir}/zick
%license LICENSE
%doc README.md CHANGELOG.md

%changelog
* Wed Aug 13 2026 Daniel Jay Haskin <djhaskin987@gmail.com> - 0.1.0-1
- Initial release.
