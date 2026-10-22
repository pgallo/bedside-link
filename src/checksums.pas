{ Frame integrity checks used by the simulated device protocols. }
unit Checksums;

{$mode objfpc}{$H+}

interface

{ CRC-16/CCITT-FALSE: poly $1021, init $FFFF, no reflection, no final xor.
  Check value for '123456789' is $29B1. }
function Crc16Ccitt(const Data; Len: SizeInt; Seed: Word = $FFFF): Word;
function Crc16CcittStr(const S: AnsiString): Word;

{ Modulo-256 sum of all bytes (monitor protocol). }
function Sum8(const S: AnsiString): Byte;

{ XOR of all bytes (infusion pump protocol). }
function Xor8(const S: AnsiString): Byte;

function HexNibble(C: AnsiChar; out V: Byte): Boolean;
function ParseHexByte(const S: AnsiString; out V: Byte): Boolean;

implementation

uses
  SysUtils;

var
  CrcTable: array[0..255] of Word;

{$R-}{$Q-}
procedure BuildCrcTable;
var
  I, J: Integer;
  C: Word;
begin
  for I := 0 to 255 do
  begin
    C := Word(I shl 8);
    for J := 1 to 8 do
      if (C and $8000) <> 0 then
        C := Word((C shl 1) xor $1021)
      else
        C := Word(C shl 1);
    CrcTable[I] := C;
  end;
end;

function Crc16Ccitt(const Data; Len: SizeInt; Seed: Word): Word;
var
  P: PByte;
  I: SizeInt;
begin
  Result := Seed;
  P := @Data;
  for I := 0 to Len - 1 do
    Result := Word((Result shl 8) xor CrcTable[((Result shr 8) xor P[I]) and $FF]);
end;

function Sum8(const S: AnsiString): Byte;
var
  I: Integer;
  Acc: Cardinal;
begin
  Acc := 0;
  for I := 1 to Length(S) do
    Acc := Acc + Ord(S[I]);
  Result := Byte(Acc and $FF);
end;
{$R+}{$Q+}

function Crc16CcittStr(const S: AnsiString): Word;
begin
  if S = '' then
    Exit($FFFF);
  Result := Crc16Ccitt(S[1], Length(S));
end;

function Xor8(const S: AnsiString): Byte;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do
    Result := Result xor Ord(S[I]);
end;

function HexNibble(C: AnsiChar; out V: Byte): Boolean;
begin
  Result := True;
  case C of
    '0'..'9': V := Ord(C) - Ord('0');
    'A'..'F': V := Ord(C) - Ord('A') + 10;
    'a'..'f': V := Ord(C) - Ord('a') + 10;
  else
    V := 0;
    Result := False;
  end;
end;

function ParseHexByte(const S: AnsiString; out V: Byte): Boolean;
var
  Hi, Lo: Byte;
begin
  V := 0;
  Result := (Length(S) = 2) and HexNibble(S[1], Hi) and HexNibble(S[2], Lo);
  if Result then
    V := (Hi shl 4) or Lo;
end;

initialization
  BuildCrcTable;
end.
