param([string]$Package,[string]$Destination)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $Destination -Force|Out-Null
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ReadOnlyMsiTools {
 [DllImport("msi.dll",CharSet=CharSet.Unicode)] static extern uint MsiOpenDatabase(string path,IntPtr mode,out uint db);
 [DllImport("msi.dll",CharSet=CharSet.Unicode)] static extern uint MsiDatabaseOpenView(uint db,string sql,out uint view);
 [DllImport("msi.dll")] static extern uint MsiViewExecute(uint view,uint record);
 [DllImport("msi.dll")] static extern uint MsiViewFetch(uint view,out uint record);
 [DllImport("msi.dll",CharSet=CharSet.Unicode)] static extern uint MsiRecordGetString(uint record,uint field,StringBuilder value,ref uint size);
 [DllImport("msi.dll")] static extern uint MsiRecordReadStream(uint record,uint field,byte[] value,ref uint size);
 [DllImport("msi.dll")] static extern uint MsiCloseHandle(uint handle);
 static void Check(uint code){if(code!=0)throw new Exception("MSI read failed: "+code);}
 static string Str(uint record,uint field){uint n=1024;var b=new StringBuilder(1025);Check(MsiRecordGetString(record,field,b,ref n));return b.ToString();}
 public static Dictionary<string,string> Extract(string path,string destination){
  uint db=0,view=0,record=0; var names=new Dictionary<string,string>();
  // MSIDBOPEN_READONLY (0): no installation and no writes to the package.
  Check(MsiOpenDatabase(path,IntPtr.Zero,out db));
  try{
   Check(MsiDatabaseOpenView(db,"SELECT `Name`, `Data` FROM `_Streams`",out view));Check(MsiViewExecute(view,0));
   while(true){uint c=MsiViewFetch(view,out record);if(c==259)break;Check(c);
    try{string name=Str(record,1);if(!name.EndsWith(".cab",StringComparison.OrdinalIgnoreCase))continue;
     if(Path.GetFileName(name)!=name)throw new Exception("Unexpected cabinet name");
     using(var output=File.Create(Path.Combine(destination,name))){byte[] buffer=new byte[65536];while(true){uint n=(uint)buffer.Length;Check(MsiRecordReadStream(record,2,buffer,ref n));if(n==0)break;output.Write(buffer,0,(int)n);}}
    }finally{MsiCloseHandle(record);record=0;}
   }
   MsiCloseHandle(view);view=0;
   Check(MsiDatabaseOpenView(db,"SELECT `File`, `FileName` FROM `File`",out view));Check(MsiViewExecute(view,0));
   while(true){uint c=MsiViewFetch(view,out record);if(c==259)break;Check(c);try{string[] parts=Str(record,2).Split('|');names[Str(record,1)]=parts[parts.Length-1];}finally{MsiCloseHandle(record);record=0;}}
  }finally{if(record!=0)MsiCloseHandle(record);if(view!=0)MsiCloseHandle(view);MsiCloseHandle(db);}
  return names;
 }
}
'@
$files=[ReadOnlyMsiTools]::Extract([IO.Path]::GetFullPath($Package),[IO.Path]::GetFullPath($Destination))
$cabinetFiles=@(Get-ChildItem -LiteralPath $Destination -Filter '*.cab' -File)
if(-not$cabinetFiles.Count){throw 'No embedded cabinet found.'}
foreach($cab in $cabinetFiles){& 'C:\Windows\System32\expand.exe' $cab.FullName '-F:*' $Destination|Out-Null;if($LASTEXITCODE -ne 0){throw 'Cabinet extraction failed.'}}
foreach($id in $files.Keys){if($files[$id] -in @('7z.exe','7z.dll')){Copy-Item -LiteralPath (Join-Path $Destination $id) -Destination (Join-Path $Destination $files[$id]) -Force}}
Get-Item -LiteralPath (Join-Path $Destination '7z.exe'),(Join-Path $Destination '7z.dll')|Select-Object FullName,Length
