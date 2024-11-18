%define version      __VERSION__
%define release      __RELEASE__
%define _topdir      /build/rpmbuild
%define buildarch    noarch
%define name         ha-lizard
%define buildroot    %{_topdir}/BUILD

Name:           %{name}
Version:        %{version}
Release:        %{release}
Summary:        High Availability for XenServer and Xen Cloud Platform XAPI based dom0s

Packager:       ha-lizard
BuildArch:      noarch
License:        GPLv3
URL:            http://www.ha-lizard.com
BuildRoot:      /build/rpmbuild/BUILD 

%description
HA-lizard provides complete automation for managing Xen server pools which utilize the XAPI management interface and toolstack (as in Xen Cloud Platform and XenServer). This hyper-converged software suite provides complete HA features within a given pool. The overall design is intended to be lightweight with no compromise of system stability. Traditional cluster management suites are not required. HA is provided with built in logic for detecting and recovering failed services and hosts.

HA features provided:

Auto-start of any failed VMs
Auto-start of any VMs on host boot
Detection of failed hosts and automated recovery of any affected VMs
Detect and clean up orphaned resources after a failed host is removed
Removal of any failed hosts from pool with takeover of services
Fencing support for HP ILO, XVM and POOL fencing (forceful removal of host from pool)
Split brain prevention using heuristics from external network points and quorum
HA support for pools with two hosts
Structured interface for simple “bolt-on” of fencing scripts
Dual operating modes for applying HA to appliances or individual VMs
Ability to exclude selected appliances and VMs from HA logic
Auto detection of host status allows for safely working on hosts without disabling HA
Centralized configuration for entire pool stored in XAPI database
Command-line tool for managing global configuration parameters
Parameter override available per host for custom configurations
HA can be enabled/disabled via command line tool or graphical interface (like XenCenter)
Extensive Logging capabilities to system log file
Email alerting on configurable triggers
Dynamic cluster management logic auto-selects roles and determines recovery policy
No changes to existing pool configuration required. All logic is external
No dependencies – does not compromise pool stability or introduce complex SW packages.
Designed to work with the resident packages on a standard XCP/XenServer host

%prep
exit 0

%build
exit 0

%pre
exit 0

%post
#!/bin/bash
##########################
## Set executable
##########################
chmod +x /etc/ha-lizard/scripts/*
chmod +x /etc/ha-lizard/init/*
chmod +x /etc/ha-lizard/ha-lizard.sh
FENCE_PATH='/etc/ha-lizard/fence/'
FENCE_METHODS=`ls $FENCE_PATH`
for i in ${FENCE_METHODS[@]}
do
	chmod +x $FENCE_PATH/$i/*.sh
	chmod +x $FENCE_PATH/$i/*.tcl
done

############################
## Place CLI link in path
############################
if [ ! -h /bin/ha-cfg ]
then
	ln -s /etc/ha-lizard/scripts/ha-cfg /bin/ha-cfg
fi

############################
## Tab completion for CLI
############################
cp /etc/ha-lizard/scripts/ha-cfg.completion /etc/bash_completion.d/ha-cfg
chmod +x /etc/bash_completion.d/ha-cfg

############################
## Init Scripts
############################
cp /etc/ha-lizard/init/ha-lizard /etc/init.d/
cp /etc/ha-lizard/init/ha-lizard-watchdog /etc/init.d/
if [ -e $(which systemctl) ]
then
	systemctl daemon-reload
fi

############################
## Bootstrap initial start
############################
cat /etc/ha-lizard/scripts/install.params > /etc/ha-lizard/ha-lizard.pool.conf

############################
## Set to autostart
############################
chkconfig ha-lizard on &>/dev/null
chkconfig ha-lizard-watchdog on &>/dev/null

############################
## Create DB Keys
############################
POOL_UUID=`xe pool-list --minimal`
xe pool-param-add uuid=$POOL_UUID param-name=other-config XenCenter.CustomFields.ha-lizard-enabled=false &>/dev/null || true
xe pool-param-add uuid=$POOL_UUID param-name=other-config autopromote_uuid="" &>/dev/null || true
/etc/ha-lizard/scripts/ha-cfg insert &>/dev/null

############################
## Update installation
## version
############################
/etc/ha-lizard/scripts/post_version.py HAL-__VERSION__-__RELEASE__

%preun
#!/bin/bash
if [ $1 = 1 ]
then
	######################
	## Don't stop on upg
	######################
	exit 0
else
	service ha-lizard-watchdog stop &>/dev/null
	service ha-lizard stop &>/dev/null
fi

%postun
#!/bin/bash
if [ $1 -eq 1 ]
then
	########################
	## This is an upgrade
	## dont't delete new ver
	########################
	exit 0
else

	chkconfig --del ha-lizard
	chkconfig --del ha-lizard-watchdog
	rm -f /bin/ha-cfg
	rm -f /etc/init.d/ha-lizard
	rm -f /etc/init.d/ha-lizard-watchdog
	rm -f /etc/bash_completion.d/ha-cfg
fi

%files
%defattr(-,root,root)
/etc/ha-lizard

