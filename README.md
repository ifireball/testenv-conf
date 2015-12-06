# Scripts for configuring and using testing environments

This repository includes shell scripts for configuring testing environments on
to of [Lago][1], and running some automated tests when applicable.

This repository includes the following scripts:
* [satellite-testing.bash](#a2) - A script for testing [Satellite][2] with
  [Robottelo][3].
* [jenkins.bash](#a3) - A script for setting up a [Jenkins][4] job testing
  environment.

[1]: http://lago.readthedocs.org/en/latest/
[2]: https://access.redhat.com/products/red-hat-satellite
[3]: http://robottelo.readthedocs.org/en/latest/
[4]: https://jenkins-ci.org/

## <a name="a1"></a>General setup

To run any of the scripts here you will need **Lago** to be installed, you can
do that by following the [Lago README][5]. You will need to follow the
"*Installation*", "*Machine set-up*" and "*User setup*" sections.

Besides setting up **Lago**, you will need to create a working directory for the
testing environments to be created inside. By default that directory should be:

    $HOME/src/workspace

You can setup a different directory by setting up the `LAGO_WS_ROOT` environment
varaible whenever you run one of the scripts.

[5]: http://lago.readthedocs.org/en/latest/README.html

## <a name="a2"></a>satellite-testing.bash

The **satellite-testing.bash** script is used to setup a testing environment
for **Satellite** and run **Robottelo** tests against it.

### Requirements

Before running this script, the following requirements must be met:

* **Lago** must be installed as specified in the [General Setup](#a1) section
  above. A workspace directory must also be created.
* The system running the tests must me connected to Red Hat's internal VPN as
  the **Satellite** version being tested as well as the **RHEL** version it is
  tested on top of are not currently available outside of Red Hat's internal
  network.
* The `python-virtualenv` package is required for running **Robottelo**.

### Usage

    ./satellite-testing.base [TESTNAME]

This will setup the testing environment and run the **Robottelo** test specified by
*TESTNAME* (It will essentially pass *TESTNAME* as an argumant to *make* running
against the *Makefile* in the Robbotelo repository).

The script, by default, will setup the testing environment in the following path:

    $HOME/src/workspace/satellite-testing

The above directory must not exist prior to running the script or **Lago** will
fail. The directory above it must exist however. The path to the testing
environment directory can be customized by setting the `LAGO_WS_ROOT` variable
as noted in the [General Setup](#a1) section above, or by setting the
`SATELLITE_LAGO_WORKSPACE` environment variable.

### Cleanup

In order to allow one to manually extract test results and review the testing
system, the script does not clean up after itself, and instead leaves the
testing environment in place and running. This means that running this script
twice in a row is impossible without some manual cleanup.

To perform the cleanup, the following command can be run:

    cd ~/src/workspace/satellite-testing && lagocli stop &&
	lagocli cleanup &&
	cd ~/src/workspace/ &&
	rm -rfv satellite-testing

Note that the pathes in the above command need to be changed if the location of
the testing environment was customized.

### Script action in detail

This script sets up a Lago environment with the following virtual hosts:

* `repo` - Used for storing and serving package repositories. Not currently used
  in the Robottelo tests.
* `satellite` - Serves as the main **Satellite** host.
* `host1` - Meant for use as a host managed by Satellite. Not in use currently.
* `host2` - Meant for use as a host managed by Satellite. Not in use currently.

The script also sets up the following virtual networks:

* `testenv` - The default **Lago** network used to manage the virtual hosts.
* `sat` - An isolated network meant to be managed with **DNS** and **DHCP**
  services provided by **Satellite**.

Once the testing environment is created, the script does the following:

1. Install **Satellite** on the `satellite` virtual host ant configures it with
   a full-blown **capsule**, including managed **DNS** and **DHCP** services.
2. Clone the **Robotello** `master` branch from **GitHub** and set it up with
   its dependencies inside a Python virtual environment.
3. Create a **Robotello** configuration file instructing it how to connect to
   the **Lago** virtual environment and the **Satellite** instance within.
4. Run **Robottelo** tests.

## <a name="a3"></a>jenkins.bash

The **jenkins.bash** script can be used to setup a Lago environment useful for
creating and testing **Jenkins** jobs.

The environment created by this script includes the following virtual hosts:
* `jenkins` - Used for hosting **Jenkins** itself.
* `builder` - Used for hosting a **Jenkins** slave.

### Requirements

Before running this script, the following requirements must be met:

* **Lago** must be installed as specified in the [General Setup](#a1) section
  above. A workspace directory must also be created.
* The operating system used by the virtaul machines setup by Lago is a cloud
  version or RHEL that is only available from resources inside the Red Hat
  netowrk, so a connection to the Red Hat VPN is required when running this
  script.

### Usage

    ./jenkins.bash

This will setup the testing environment and install **Jenkins** inside it. Once
the script had run, one can go into the testing environment directory (noted
below) and use the `lagocli shell jenkins` command to access the **Jenkins**
server, or run `lagocli status` to see the **Jenkins** server's IP address that
can be used to access it with a web browser.

The script, by default, will setup the testing environment in the following path:

    $HOME/src/workspace/jenkins

The above directory must not exist prior to running the script or **Lago** will
fail. The directory above it must exist however. The path to the testing
environment directory can be customized by setting the `LAGO_WS_ROOT` variable
as noted in the [General Setup](#a1) section above, or by setting the
`JENKINS_LAGO_WORKSPACE` environment variable.
