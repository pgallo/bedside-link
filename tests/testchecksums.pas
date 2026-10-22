unit TestChecksums;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Checksums;

type
  TChecksumTests = class(TTestCase)
  published
    procedure Crc16CheckValue;
    procedure Crc16EmptyIsInit;
    procedure Crc16IsIncremental;
    procedure Crc16DetectsSingleBitFlip;
    procedure Sum8Wraps;
    procedure Xor8KnownValue;
    procedure HexByteParsing;
  end;

implementation

procedure TChecksumTests.Crc16CheckValue;
begin
  // Catalogue check value for CRC-16/CCITT-FALSE.
  AssertEquals($29B1, Crc16CcittStr('123456789'));
end;

procedure TChecksumTests.Crc16EmptyIsInit;
begin
  AssertEquals($FFFF, Crc16CcittStr(''));
end;

procedure TChecksumTests.Crc16IsIncremental;
var
  A, B: AnsiString;
  Partial: Word;
begin
  A := '12345';
  B := '6789';
  Partial := Crc16Ccitt(A[1], Length(A));
  AssertEquals($29B1, Crc16Ccitt(B[1], Length(B), Partial));
end;

procedure TChecksumTests.Crc16DetectsSingleBitFlip;
var
  S, T: AnsiString;
  I, Bit: Integer;
  Ref: Word;
begin
  S := 'ventilator frame payload';
  Ref := Crc16CcittStr(S);
  for I := 1 to Length(S) do
    for Bit := 0 to 7 do
    begin
      T := S;
      T[I] := Chr(Ord(T[I]) xor (1 shl Bit));
      AssertFalse(Format('flip at %d.%d undetected', [I, Bit]), Crc16CcittStr(T) = Ref);
    end;
end;

procedure TChecksumTests.Sum8Wraps;
begin
  AssertEquals(0, Sum8(''));
  AssertEquals(Ord('A') + Ord('B'), Sum8('AB'));
  AssertEquals((255 * 3) and $FF, Sum8(#255#255#255));
end;

procedure TChecksumTests.Xor8KnownValue;
begin
  AssertEquals(0, Xor8('AA'));
  AssertEquals(Ord('A') xor Ord('B') xor Ord('C'), Xor8('ABC'));
end;

procedure TChecksumTests.HexByteParsing;
var
  V: Byte;
begin
  AssertTrue(ParseHexByte('5B', V));
  AssertEquals($5B, V);
  AssertTrue(ParseHexByte('ff', V));
  AssertEquals($FF, V);
  AssertFalse(ParseHexByte('G1', V));
  AssertFalse(ParseHexByte('1', V));
  AssertFalse(ParseHexByte('123', V));
end;

initialization
  RegisterTest(TChecksumTests);
end.
