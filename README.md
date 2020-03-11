# Z-Way
Zway plugin for openLuup 

Why Migrate? If you are reading this, you probably already know but just in case...

Because Z-way is a far more stable platform than the vera especially on larger networks. The vera current state has such fundamental design flaws that it is nearly unuseable for any network above ~40 devices. It becomes too chatty and error prone.
Even on smaller networks, the notoriously absurd abuse of luup reloads and forced deletion and creation of devices has turned away mor than one customer.

Z-way-server on the other hand is built on a much more stable and solid API and zwave library. The "Expert UI" can pretty much support any device which has nothing propriatory. It's smarthome UI, which API this plugin relies on however has its flaws, filtering out useful command classes and requiring some workaround to address the lower level API.

Assuming that the entire automation setup (scenes and plugins) have already been migrated to openLuup, you can now migrate the zwave hub and take advantage of the best part of the vera, it's object data structure, API and lua/plugins, and get rid of its instability.

# Guide to migrate from Vera as a zwave device hub to Z-way:

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
7. Upon reboot of the vera you should see all your old zwave devices repopulated with new names and without room assignments. Success! You have cloned your zwave dongle into the uzb.

B. Security key. (S0)

If you previously succesfully included or shifted the z-way into the vera's network with the security key then the key will be in your /z-way-server/config/zddx/config*** file at the entry line 57. If not you can always ask vera's support for the way to extract the key as they deleted my post which provided the instructions to do so. I will not post it here. You will need this key (16 bytes) if you have secure class devices on your network.

C. Configure Z-way

Move the uzb to your z-way-server machine and start z-way. Make sure that the zwave app has your uzb as its dongle device. Again it should be /dev/ttyACM0 if you are on a linux machine. You could also keep the uzb in the vera, nuke the vera software and forward the uzb serial port over IP to a virtual machine containing the z-wave-me server. This is a topic for another chapter.
Once zway is up and running, go to the Expert UI and send a "NIF" (Node Information Frame) in the controller menu to every node. You may need to wakeup the sleepy nodes to interview them. Some devices may need a configuration change to work with z-way vs. vera. Ask on the forum if you run into something like this and can't figure it out. As devices get interviewed, their configurations get populated and virtual devices will show up in zway's Smarthome UI. You should not need to worry about associations since you cloned the controller's ID. For more information on interviews, consult the z-way manual.

D. Install the Z-way2 Bridge

