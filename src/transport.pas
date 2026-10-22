{ Byte transports. The gateway only needs "give me up to N bytes", so any
  TStream can sit underneath: a THandleStream over a serial port file
  descriptor, a TSocketStream to a terminal server, or the replay transport
  used by the demo and tests. }
unit Transport;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TTransport = class
  private
    FName: string;
  public
    constructor Create(const AName: string);
    { Returns the number of bytes copied into Buf (0 when nothing is available
      right now). Never blocks for longer than the transport's own timeout. }
    function Read(var Buf; Count: Integer): Integer; virtual; abstract;
    { True once a finite source is exhausted. Live links never report it. }
    function Eof: Boolean; virtual; abstract;
    property Name: string read FName;
  end;

  TStreamTransport = class(TTransport)
  private
    FStream: TStream;
    FOwnsStream: Boolean;
  public
    constructor Create(const AName: string; AStream: TStream; AOwnsStream: Boolean);
    destructor Destroy; override;
    function Read(var Buf; Count: Integer): Integer; override;
    function Eof: Boolean; override;
    property Stream: TStream read FStream;
  end;

  { Replays a recorded byte stream and deliberately fragments it: each read
    returns a pseudo-random number of bytes between 1 and MaxChunk, so frames
    arrive split at arbitrary positions, as they do from a UART FIFO or a TCP
    segment. A fixed seed keeps every run reproducible. }
  TReplayTransport = class(TStreamTransport)
  private
    FMaxChunk: Integer;
    FSeed: Cardinal;
    function NextChunk: Integer;
  public
    constructor Create(const AName: string; AData: TStream; AMaxChunk: Integer;
      ASeed: Cardinal = 1);
    constructor CreateFromFile(const AFileName: string; AMaxChunk: Integer;
      ASeed: Cardinal = 1);
    constructor CreateFromString(const AName: string; const AData: AnsiString;
      AMaxChunk: Integer; ASeed: Cardinal = 1);
    function Read(var Buf; Count: Integer): Integer; override;
  end;

implementation

{ TTransport }

constructor TTransport.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

{ TStreamTransport }

constructor TStreamTransport.Create(const AName: string; AStream: TStream;
  AOwnsStream: Boolean);
begin
  inherited Create(AName);
  FStream := AStream;
  FOwnsStream := AOwnsStream;
end;

destructor TStreamTransport.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited Destroy;
end;

function TStreamTransport.Read(var Buf; Count: Integer): Integer;
begin
  Result := FStream.Read(Buf, Count);
end;

function TStreamTransport.Eof: Boolean;
begin
  Result := FStream.Position >= FStream.Size;
end;

{ TReplayTransport }

constructor TReplayTransport.Create(const AName: string; AData: TStream;
  AMaxChunk: Integer; ASeed: Cardinal);
begin
  inherited Create(AName, AData, True);
  if AMaxChunk < 1 then
    AMaxChunk := 1;
  FMaxChunk := AMaxChunk;
  FSeed := ASeed;
end;

constructor TReplayTransport.CreateFromFile(const AFileName: string;
  AMaxChunk: Integer; ASeed: Cardinal);
var
  M: TMemoryStream;
begin
  M := TMemoryStream.Create;
  try
    M.LoadFromFile(AFileName);
  except
    M.Free;
    raise;
  end;
  Create(ExtractFileName(AFileName), M, AMaxChunk, ASeed);
end;

constructor TReplayTransport.CreateFromString(const AName: string;
  const AData: AnsiString; AMaxChunk: Integer; ASeed: Cardinal);
var
  S: TStringStream;
begin
  S := TStringStream.Create(AData);
  Create(AName, S, AMaxChunk, ASeed);
end;

{$Q-}{$R-}
function TReplayTransport.NextChunk: Integer;
begin
  // 32-bit linear congruential generator; quality is irrelevant here,
  // reproducibility across compilers is what matters.
  FSeed := FSeed * 1664525 + 1013904223;
  Result := 1 + Integer((FSeed shr 16) mod Cardinal(FMaxChunk));
end;
{$Q+}{$R+}

function TReplayTransport.Read(var Buf; Count: Integer): Integer;
var
  N: Integer;
begin
  N := NextChunk;
  if N > Count then
    N := Count;
  Result := inherited Read(Buf, N);
end;

end.
