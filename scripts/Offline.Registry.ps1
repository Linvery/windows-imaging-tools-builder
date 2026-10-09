function Get-OfflineImageState {
    param([Parameter(Mandatory=$true)][string]$HivePath)
    if (-not ('PveOffline.HiveFileReader' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
namespace PveOffline {
    public sealed class HiveFileReader {
        private readonly byte[] data;
        private HiveFileReader(string file) {
            var info = new FileInfo(file);
            if (info.Length < 4096 || info.Length > 512L*1024*1024) throw new InvalidDataException("Unsupported registry hive size.");
            data = File.ReadAllBytes(file);
            if (Encoding.ASCII.GetString(data, 0, 4) != "regf") throw new InvalidDataException("Not a registry hive.");
            if (U32(20) != 1 || U32(24) > 6) throw new InvalidDataException("Unsupported registry hive format.");
        }
        private void Bounds(int at, int size) {
            if (at < 0 || size < 0 || at > data.Length-size) throw new InvalidDataException("Registry cell is outside the hive.");
        }
        private uint U32(int at) { Bounds(at,4); return BitConverter.ToUInt32(data,at); }
        private ushort U16(int at) { Bounds(at,2); return BitConverter.ToUInt16(data,at); }
        private int Cell(uint relative) {
            long at = 4096L + relative;
            if (at > int.MaxValue) throw new InvalidDataException("Invalid registry cell offset.");
            int offset = (int)at;
            Bounds(offset,4);
            int size = BitConverter.ToInt32(data,offset);
            if (size >= -4 || size == int.MinValue) throw new InvalidDataException("Registry cell is not allocated.");
            Bounds(offset,-size);
            return offset+4;
        }
        private string Signature(int at) { Bounds(at,2); return Encoding.ASCII.GetString(data,at,2); }
        private string Name(int at, int size, bool ascii) {
            Bounds(at,size);
            return (ascii ? Encoding.GetEncoding(1252) : Encoding.Unicode).GetString(data,at,size);
        }
        private string KeyName(int at) {
            if (Signature(at) != "nk") throw new InvalidDataException("Expected a registry key cell.");
            return Name(at+76,U16(at+72),(U16(at+2)&0x20)!=0);
        }
        private IEnumerable<uint> Subkeys(uint index, int depth) {
            if (depth > 32) throw new InvalidDataException("Registry subkey index is too deep.");
            int at=Cell(index); string kind=Signature(at); int count=U16(at+2);
            if (kind=="lf" || kind=="lh") {
                Bounds(at+4,count*8);
                for(int i=0;i<count;i++) yield return U32(at+4+i*8);
            } else if(kind=="li" || kind=="ri") {
                Bounds(at+4,count*4);
                for(int i=0;i<count;i++) {
                    uint next=U32(at+4+i*4);
                    if(kind=="li") yield return next;
                    else foreach(uint child in Subkeys(next,depth+1)) yield return child;
                }
            } else throw new InvalidDataException("Unsupported registry subkey index.");
        }
        private uint FindChild(uint parent,string name) {
            int at=Cell(parent);
            if (Signature(at)!="nk" || U32(at+20)==0) throw new InvalidDataException("Offline registry key is missing: "+name);
            foreach(uint child in Subkeys(U32(at+28),0))
                if(string.Equals(KeyName(Cell(child)),name,StringComparison.OrdinalIgnoreCase)) return child;
            throw new InvalidDataException("Offline registry key is missing: "+name);
        }
        private string StringValue(uint key,string name) {
            int at=Cell(key); uint count=U32(at+36);
            if(count>100000) throw new InvalidDataException("Invalid registry value count.");
            int values=Cell(U32(at+40)); Bounds(values,checked((int)count*4));
            for(int i=0;i<(int)count;i++) {
                int value=Cell(U32(values+i*4));
                if(Signature(value)!="vk") throw new InvalidDataException("Invalid registry value cell.");
                string valueName=Name(value+20,U16(value+2),(U16(value+16)&1)!=0);
                if(!string.Equals(valueName,name,StringComparison.OrdinalIgnoreCase)) continue;
                if(U32(value+12)!=1) throw new InvalidDataException("Expected a REG_SZ registry value.");
                uint length=U32(value+4); bool inline=(length&0x80000000)!=0; length&=0x7fffffff;
                if(length>4096 || (inline && length>4) || length%2!=0) throw new InvalidDataException("Invalid registry string size.");
                int text=inline ? value+8 : Cell(U32(value+8));
                return Name(text,(int)length,false).TrimEnd((char)0);
            }
            throw new InvalidDataException("Offline registry value is missing: "+name);
        }
        public static string ReadImageState(string file) {
            var hive=new HiveFileReader(file);
            uint key=hive.U32(36);
            foreach(string segment in new[]{"Microsoft","Windows","CurrentVersion","Setup","State"}) key=hive.FindChild(key,segment);
            return hive.StringValue(key,"ImageState");
        }
    }
}
"@
    }
    [PveOffline.HiveFileReader]::ReadImageState([IO.Path]::GetFullPath($HivePath))
}
