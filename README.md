# Thunderhammer
A custom device that can be used to mount Rowhammer through either a Thunderbolt port or a PCIe slot. 

## Basic principles of use and security relevance
Rowhammer is a DRAM vulnerability wherein repeatedly accessing ('hammering') rows in system memory can flip bits in adjacent rows, violating security guarantees that are predicated on memory isolation.
Our Thunderhammer device can issue memory requests over PCIe and Thunderbolt (tunnelling PCIe) to induce Rowhammer bitflips. 

## Paper report
This device is an artefact of research that has been published in a paper titled:  
_Thunderhammer: Rowhammer Bitflips via PCIe and Thunderbolt (USB-C)_  
Preprint available on [arXiv](https://arxiv.org/abs/2509.11440) (2509.11440).

## Scripts
We include some scripts containing pcileech commands that can be used for the various phases of Rowhammer evaluation: priming victim and aggressor rows with 1's and 0's, initiating hammering, then dumping out victim row contents and analysing for any bitflips. 

## Device
Modified RTL for ZDMA device - based on the [pcileech-fpga/ZDMA](https://github.com/ufrisk/pcileech-fpga/tree/master/ZDMA) project, and for use interacting with the [pcileech](https://github.com/ufrisk/pcileech) codebase.

The modifications primarily allow us to send a sequence of PCIe TLPs (packets) which the device will then repeatedly re-transmit in a loop to the target for hammering.
Under the current configurations the ZDMA will transmit in a loop until it has completed the requested number of transmissions, or it can be set to stop earlier as soon as the target system throttles the ZDMA (from being overwhelmed) during the transmission looping. 
In either case, the ZDMA will signal back to the control software whenever throttling has occurred, then since the remaining looping may take variable time given throttling down-time, the ZDMA will additionally signal the end of looping. 
If no throttling occurs, the looping finishes in the expected time (with no additional signalling from the ZDMA).
Other modifications also enable operation when plugged into a target with virtualisation enabled (protected by VT-d/IOMMU). 

### Transmission loop-out

The structure of our packet sequence is:

[ START | INTERVAL | ... | ... | END ]

To invoke repeated transmissions we must modify some of the TLP fields (calling this a sub-packet).  
We use the Requester ID and Tag fields for signalling. These are bits [32-55].  
The general structure of our signalling sub-packets is as follows:

[ 4-bit control signal | 20-bit data/value signal ]

Note, this signalling is only to talk to our control logic in the ZDMA, which then overwrites the Requester ID field of the forwarded packets (those ultimately transmitted over PCIe lanes) with the correct values. 

**Readout:** If the repeated transmissions include read requests then the data coming back from the target (within completion TLPs) might overwhelm our ZDMA buffers. 
For this reason, by default the ZDMA is set to discard completions received while looping. 
However, this behaviour can be changed by also setting the last control bit in the START packet, see below in START (with readout) description.  

**Rotating tags:** The looping function will also increment the tag of each TLP transmitted. 

* START: this is the first packet in the loop sequence. The data field indicates how many total (128-bit) packet transmissions the ZDMA should make in looping. The number provided is multiplied by 2^15 (32,768). Binary format: 
    
    [ 1000 | < number of 128-bit packet transmissions / 2^15 > ]

    *e.g. (from Windows Powershell script example in /scripts/hammer.ps1)* this is the 0x808000 portion of the following 64-bit read TLP:

    ```
    Start-Process -FilePath "pcileech.exe" -ArgumentList "tlp", "-in", "2000100180800001000000018701E000", "-vvv" -NoNewWindow -Wait
    ```
    
    In this example the value provided is 0x08000, which multiplied by 0x8000 (2^15) becomes 0x40000000 total packet transmissions (~1 billion).
    
    *So TLPs that are over 128 bits (and under or up to 256), like a 64-bit write with its payload, will count for two of these packet transmissions.*

* START (with readout): Same as above but the ZDMA will read back data received from looped read TLPs, also the number provided is as is (not multiplied by 2^15) plus the number of packets in the sequence, i.e. setting it to zero will cause one full transmission loop. Binary format: 
    
    [ 1001 | < number of 128-bit packet transmissions > ]

    *e.g. (from Windows Powershell script example in /scripts/hammer.ps1)* this is the 0x908000 portion of the following 64-bit read TLP:

    ```
    Start-Process -FilePath "pcileech.exe" -ArgumentList "tlp", "-in", "2000100190800001000000018701E000", "-vvv" -NoNewWindow -Wait
    ```
    
    In this example the value provided is 0x08000 (~32,000 total packet transmissions).

    Note: when readout is not set, the ZDMA core is configured to discard responses received from the target *only* while looping transmissions.
    This means once the transmit loop has finished, responses from the last few read requests (that arrive slightly later) sent will not be discarded and instead will be sent from the ZDMA to the control software. 
    
* START (with halt upon throttling) (in this case with the readout bit set, but that can also be off): same as above but the ZDMA will stop its transmission loop upon the first instance of it undergoing throttling from the PCIe bus. 

    [ 1011 | < number of 128-bit packet transmissions > ]

    *e.g. (from Windows Powershell script example in /scripts/hammer.ps1)* this is the 0xB08000 portion of the following 64-bit read TLP:

    ```
    Start-Process -FilePath "pcileech.exe" -ArgumentList "tlp", "-in", "20001001B0800001000000018701E000", "-vvv" -NoNewWindow -Wait
    ```

* INTERVAL: this packet indicates the size of the interval between overall START-END loop batches, i.e. the interval between finishing the transmission of an END packet and the transmission of the next START packet. Similarly measured in clock cycles. Binary format: 

    [ 0010 | < length of intervals > ] 

    *e.g. (from Powershell script)* this is the 0x200003 portion of the following 64-bit read TLP:

    ```
    Start-Process -FilePath "pcileech.exe" -ArgumentList "tlp", "-in", "20001001200003010000000183878000", "-vvv" -NoNewWindow -Wait
    ```
    There is a small bug that stops this from working if the gap between packets (defined in the START message) inside a batch is 0, so use at least a gap of 1 for that.

* END: the last packet in the loop sequence. The data field indicates the size of the intervals between packet transmissions in the packets within an overall START-END loop. The interval is measured in clock cycles for a 125MHz clock, so each unit is 8ns. Binary format: 

    [ 0100 | < length of interval > ]

    *e.g. (from Powershell script)* this is the 0x400003 portion of the following 64-bit read TLP:

    ```
    Start-Process -FilePath "pcileech.exe" -ArgumentList "tlp", "-in", "20001001400003010000000183F14000", "-vvv" -NoNewWindow -Wait
    ```
    In this example the value provided is 0x00003, so there is a 3 x 8ns = 24ns gap between packets. 
    
    Note, this means that if you send 128-bit packets such as a 64-bit read TLP (which each take 1 clock cycle = 8ns to transmit) then a packet is sent every 8 + 24 = 32ns. Whereas if you send larger TLPs like 64-bit writes with payload (with more than 128 but up to 256-bits) (this takes 2 clock cycles = 16ns) then packets are sent every 16 + 24 = 40ns. 

&nbsp;

**Throttle signal:** If the ZDMA's PCIe connection has been throttled (a signal that the memory controller is overwhelmed), the ZDMA will send back a TLP full of ones (FFs) to the control software.
All 128 bits of the packet are set to 1. 
See below how this looks from control software. 
Note, this packet will come among all the other packets being read back from ZDMA, even in the case that readout is not requested, though in that case it should be the first RX (received) packet. 

```
RX: TLP???: TypeFmt: ff dwLen: 3ff
0000    ff ff ff ff ff ff ff ff  ff ff ff ff ff ff ff ff   ................
```

**End of loop after throttle signal:** The same TLP (of FFs) above will be sent when looping without halt upon throttling is requested. After the first FF packet (indicating throttling) is received, the next one will indicate the transmission looping has finished. 


### Virtualisation support

In virtualised environments memory isolation is enforced by an IOMMU. This restricts PCIe/Thunderbolt devices to only making requests to their allocated virtual memory regions. When the device driver is loaded, it requests a memory allocation which it then communicates to the device by writing to one of its BARs (Base Address Register). Our modified ZDMA supports a specially crafted TLP to read out all overwritten BAR contents (those overwritten since zeroisation at powerup) back to the control machine. 

To dump BAR contents send a TLP with all bits that correspond to the ``Type`` field set to one. These are bits [3-7] of the PCIe packet (not related to the subpacket we use for signalling START-INTERVAL-END).  
Then set ``-tlpwait`` on with some time to let the pcileech binary listen to incoming response TLPs from the ZDMA. 

Note, this is a nonsensical TLP and open receiving it from software our modified ZDMA will not forward it (or anything) on to the target machine over the PCIe interface. 

*e.g. (Windows cmd prompt) with more bits than needed (those before the Type field) set to one*

```
.\pcileech.exe tlp -in FF0000000000000000000000 -vvv -tlpwait 10
```

## Connecting via Thunderbolt
To connect the ZDMA via Thunderbolt we suggest using a PCIe-to-Thunderbolt chassis. For our demonstrations we use the [Startech Thunderbolt 3 PCIe Expansion Chassis (TB31PCIEX16)](https://www.startech.com/en-us/usb-hubs/tb31pciex16).

## _Disclaimers_
_In its state as provided, this is not an inherently destructive artefact. However it can be developed into one, as such we do not condone the use of this technology for illegal purposes and assume no responsibility for any damages caused._

## Author of original core
These applications are based on an original PCIe device core 'pcileech-fpga' produced by [Ulf Frisk](https://github.com/ufrisk).  
The project can be found here: https://github.com/ufrisk/pcileech-fpga

## Author of Thunderhammer modifications
[Robbie Dumitru](https://robbiedumitru.github.io/) - The University of Adelaide and Ruhr University Bochum, 2025.

## Copyright and license

Original source:  
&nbsp;&nbsp;&nbsp;&nbsp; Copyright (c) 2017 [Ulf Frisk](https://github.com/ufrisk)  
&nbsp;&nbsp;&nbsp;&nbsp; Licensed under the MIT License.  

Modified source  
&nbsp;&nbsp;&nbsp;&nbsp; Copyright (c) 2025 by Robbie Dumitru  
&nbsp;&nbsp;&nbsp;&nbsp; Licensed under Creative Commons CC0-1.0  

These applications can be freely modified, used, and distributed as long as the attributions to both the original author and author of modifications (and their employers) are not removed.

The completed solution contains Xilinx proprietary IP cores licensed under the Xilinx CORE LICENSE AGREEMENT.
This project as-is published on Github contains no Xilinx proprietary IP.
Published source code are licensed under the MIT License and the Creative Commons License.
The end user that have downloaded the no-charge Vivado WebPACK from Xilinx will have the proper licenses and will be able to re-generate Xilinx proprietary IP cores by running the build detailed above.

## Acknowledgements
#### This project was supported by:  
* an ARC Discovery Project number DP210102670
* the Deutsche Forschungsgemeinschaft (DFG, German Research Foundation) under Germany's Excellence Strategy - EXC 2092 CASA - 390781972
* the National Science Foundation (Grant No. CNS-2145744)
