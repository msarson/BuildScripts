-- Default Redirection for Clarion 10.0
-- Managed by BuildScripts - do not edit in workspace directly
-- This file is copied over the Clarion bin version after checkout

[Copy]
-- Directories only used when copying dlls
*.dll = %BIN%;%BIN%\AddIns\BackendBindings\ClarionBinding\Common;%ROOT%\Accessory\bin;%libpath%\bin\%configuration%

[Debug]
-- Directories only used when building with Debug configuration

*.obj = .\genfiles\obj
*.res = .\genfiles\res
*.rsc = .\genfiles\rsc
*.lib = .\genfiles\lib   
*.exp = .\genfiles\exp
*.rdf = .\genfiles\rdf
*.bld = .\genfiles\bld
*.shp = .\genfiles\shp
*.version = .\genfiles\Version
*.manifest = .\build
*.clw = ;.\genfiles\source
*.inc = ;.\genfiles\source
*.exe = ;.\build
*.dll = ;.\build
*.FileList.xml = .\genfiles\obj
*.map = .\genfiles\map

[Release]
-- Directories only used when building with Release configuration
*.obj = .\genfiles\obj
*.res = .\genfiles\res
*.rsc = .\genfiles\rsc
*.lib = .\genfiles\lib   
*.exp = .\genfiles\exp
*.rdf = .\genfiles\rdf
*.bld = .\genfiles\bld
*.shp = .\genfiles\shp
*.manifest = .\build
*.version = .\genfiles\Version
*.clw = ;.\genfiles\source
*.inc = ;.\genfiles\source
*.exe = ;.\build
*.dll = ;.\build
*.FileList.xml = .\genfiles\obj
*.map = .\genfiles\map

[Common]
*.ico = .\images\new_icons;.\images\ico;%ROOT%\accessory\images
*.jpg = .\images\jpg;%ROOT%\accessory\images
*.bmp = .\images\bmp;%ROOT%\accessory\images
*.gif = .\images\gif;%ROOT%\accessory\images
*.png = .\images\png;%ROOT%\accessory\images
*.cur = .\images\cur;%ROOT%\accessory\images
*.wav = ;%ROOT%\accessory\images
*.chm = %BIN%;%ROOT%\Accessory\bin
*.tp? = .\template;%ROOT%\template\win;%ROOT%\Accessory\template\win
*.trf = %ROOT%\template\win
*.txs = %ROOT%\template\win
*.stt = %ROOT%\template\win
*.*   = .;.\libsrc;%ROOT%\libsrc\win; %ROOT%\images; %ROOT%\template\win;%ROOT%\Accessory\Template\Win;%ROOT%\Accessory\LibSrc\Win;%ROOT%\Accessory\Images\Super
*.lib = %ROOT%\lib
*.obj = %ROOT%\lib
*.res = %ROOT%\lib
*.hlp = %BIN%;%ROOT%\Accessory\bin
*.dll = %BIN%;%ROOT%\Accessory\bin
*.exe = %BIN%;%ROOT%\Accessory\bin
*.txs = %ROOT%\Accessory\template\win
*.stt = %ROOT%\Accessory\template\win
*.lib = %ROOT%\Accessory\lib
*.obj = %ROOT%\Accessory\lib
*.res = %ROOT%\Accessory\lib
*.dll = %ROOT%\Accessory\bin
*.*   = .\libsrc;%ROOT%\Accessory\images; %ROOT%\Accessory\resources; %ROOT%\Accessory\libsrc\win; %ROOT%\Accessory\template\win
*.hlp = %ROOT%\bin;%ROOT%\Accessory\bin\Environment Utility;%ROOT%\Accessory\bin\Source Manager;%ROOT%\Accessory\bin\Translation Assistant;%ROOT%\Accessory\Documents\ABCFree;%ROOT%\Accessory\Vendor\LodestarSoftware\RPM\UserHelp
*.dll = %ROOT%\Accessory\addins\UpperParkSolutions.up_vc_Interface;%ROOT%\Accessory\bin\CryptoTools
*.exe = %ROOT%\Accessory\bin\CryptoTools;%ROOT%\Accessory\bin\Environment Utility;%ROOT%\Accessory\bin\iQXML;%ROOT%\Accessory\bin\mBuild;%ROOT%\Accessory\bin\Source Manager;%ROOT%\Accessory\bin\Translation Assistant;%ROOT%\Accessory\Documents\Comsoft7\BST Scheduler V5.03;%ROOT%\Accessory\Documents\Comsoft7\BST Scheduler V5.09;%ROOT%\Accessory\RptDemo;%ROOT%\Accessory\source\Office Messenger;%ROOT%\Accessory\Tools\ITPrev;%ROOT%\Accessory\Uninstall;%ROOT%\Accessory\Vendor\LodestarSoftware;%ROOT%\Accessory
*.pak= %ROOT%\Accessory\bin
*.bin= %ROOT%\Accessory\bin
*.dat= %ROOT%\Accessory\bin
[AutoAdded]
*.hlp = %ROOT%\bin
*.pak=1
*.bin=1
*.dat=1
