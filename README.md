# Z-Way
Zway plugin for openLuup 

Why Migrate?

Because Z-way is a far more stable platform than the vera especially on larger networks. The vera current state has such fundamental design flaws that it is nearly unuseable for any network above ~40 devices. It becomes too chatty and error prone.
Even on smaller networks, the notoriously absurd abuse of luup reloads and forced deletion and creation of devices has turned away mor than one customer.

Z-way-server on the other hand is built on a much more stable and solid API and zwave library. The "Expert UI" can pretty much support any device which has nothing propriatory. It's smarthome UI, which API this plugin relies on however has its flaws, filtering out useful command classes and requiring some workaround to address the lower level API.

Guide to migrate from Vera as a zwave device hub to Z-way:

There are many ways to migrate a zwave network. 
One way to initially run testing is just to add the z-way as a secondary controller to your network. Normally, the inclusion process of z-way involves a security key exchange which the vera often fails so you may need a few retries. At some point though when ready to let go of the vera, a different method will be required to give z-way the zwave primary role.
In order to do this, the official method is to run a controller shift which is similar to an inclusion but with the shifting of the primary role from the vera to the new controller. This again could require several retries due to vera's extraordinary ability to fail secure class key exchanges

My recommendation is to clone the controller. It has the advantage of not having to touch any other device on the network and some devices either only accept 1 lifeline associated controller (accept to take some packets only from one controller or worse, some devices won't even wake up to any other controller but the lifeline they had forcing the user to exclude/reinclude the device if the controller chained ID. Some devices even only accept their lifeline association to device ID1, again making having a controller not being the node ID #1 impossible for them.

A. Cloning the Vera's zwave dongle. (Vera Plus/Edge/Secure) using a zwave.me uzb stick

1. Always have a recent backup of your vera configuration handy. Preferably backup your zwave network along with your configuration now before you do anything.
2. SSH into the vera using an SSH client (i.e putty)
3. Go to /etc/cmh/ and take a look at your dongle's backup: 
   cd /etc/cmh
   ls
   You should see a bunch of "dongle.dump" files. These are the backups of your zwave chips NVM. Basically your network data, including all the node information and routing.
4. Now insert the uzb into the usb port of the vera.  
   ls /dev        should show a serial port called ttyACM0
5. Go into the vera UI and go under Settings/Z-wave settings/Options Tab and change the port field to "/dev/ttyACM0" and let the luup engine reload. This will wipe out all the zwave devices from your vera configuration (Another wonderful feature of the luup reload...) and switch you to the uzb as your zwave chip.
6. Go back to your SSH client window and still in the folder /etc/cmh/, type "touch dongle.restore", go back to the vera UI and start a luup reload. Once the luup engine has reloaded and you can see your dashboard, go to the ssh screen and type "reboot"
7. Upon reboot of the vera you should see all your old zwave devices repopulated with new names and without room assignments. Success. You have cloned your zwave dongle into the uzb.

B. Security key.
