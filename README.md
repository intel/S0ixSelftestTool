# Release Notes for S0ix Selftest Tool

Thanks for using S0ix Selftest Tool. This tool is designed for Linux OS, it can
be used to do the initial debugging for the S2idle path CPU Package C-state and
S0ix failures for Intel® Client platforms, it also supports the basic runtime PC10
status check.

When linux users' system fails to enter PC10 or S0ix via S2idle, they can use this
script to get the initial debugging infomation or potenial blockers before reporting
the bugs in the Bugzilla. This script will archive the debugging process logs,
which will be helpful for the future advanced debugging.

This tool's design follows the basic debugging process introduced in the
documents below:  
https://web.archive.org/web/20230614200816/https://01.org/blogs/qwang59/2018/how-achieve-s0ix-states-linux
https://web.archive.org/web/20230614200306/https://01.org/blogs/qwang59/2020/linux-s0ix-troubleshooting

How to use this tool?

To check S2idle Path Package C-state or S0ix, using  
`./s0ix-selftest-tool.sh -s`
Usually the users only need to wait for less than 3 minutes to get the debugging
results or messages.

To check runtime PC10 with screen on, using  
`./s0ix-selftest-tool.sh -r on`

To check runtime PC10 with screen off, using  
`./s0ix-selftest-tool.sh -r off`

Additional Notes:
1. The users need to run this tool as root account

2. If the users see "awk: line 10: function gensub never defined" message during
 running the script, please install gawk

3. If the users see "sudo: xxd: command not found" message during running the script,
please try to install a vim-common package

4. There are two binaries that will be used in this tool: turbostat and powertop

5. The acpidump tool(can be accessed by installing acpica-tools) is needed for using this tool

6. Before using this tool please disable secure boot option from BIOS setup,
which may cause Operation permission issues

7. If the users' system fails to enter S2idle, then this tool will not help. All
the s0ix debugging is based on S2idle entry and exit working normally, if there is
any driver or fw issue that blocks the S2idle functionality itself, please fix that first.

8. If the users have a good idea to improve this script, you are very welcome to send
us the patches, thanks!

