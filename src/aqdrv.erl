-module(aqdrv).
-define(DELAY,5).
-export([init/1, open/2, stage_map/4, stage_data/2, 
	stage_flush/1, write/3, inject/2, set_tunnel_connector/0, set_thread_fd/4,
	replicate_opts/2, replicate_opts/3, index_events/5, fsync/1]).

init(Info) when is_map(Info) ->
	aqdrv_nif:init(Info).

% integer hash of name for connection
% should data be compressed or not. Compression requires copying data,
% if data is already compact compression is a giant waste of resources.
open(Hash,true) ->
	aqdrv_nif:open(Hash,1);
open(Hash,false) ->
	aqdrv_nif:open(Hash,0).

% Set replicator process.
set_tunnel_connector() ->
	aqdrv_nif:set_tunnel_connector().
% Set replication socket fd.
set_thread_fd(Thread,Fd,Pos,Type) ->
	case aqdrv_nif:set_thread_fd(Thread,Fd,Pos,Type) of
		again ->
			% erlang:yield(),
			timer:sleep(?DELAY),
			set_thread_fd(Thread, Fd, Pos, Type);
		Res ->
			Res
	end.

% Make sure all data for last write on connection has been synced.
fsync({aqdrv,Con}) ->
	Ref = make_ref(),
	case aqdrv_nif:fsync(Ref, self(), Con) of
		again ->
			timer:sleep(?DELAY),
			fsync({aqdrv,Con});
		ok ->
			receive_answer(Ref)
	end.

% Replication data.
replicate_opts(Con,PacketPrefix) ->
	replicate_opts(Con,PacketPrefix,1).
replicate_opts({aqdrv, Connection},PacketPrefix,Type) ->
	ok = aqdrv_nif:replicate_opts(Connection,PacketPrefix,Type).

% After replication done, add event names to index.
index_events({aqdrv,Con},[_|_] = Names, QName, Term, Evnum) ->
	ok = aqdrv_nif:index_events(Con, Names, QName, Term, Evnum).

% Must be called before stage_data.
% Sets name of event (binary), type (unsigned char) and size of data.
stage_map({aqdrv,Con}, Name, Type, Size) ->
	aqdrv_nif:stage_map(Con, Name, Type, Size).

% Write event data. 
stage_data({aqdrv,Con}, <<_/binary>> = Bin) when byte_size(Bin) < 1024*1024*1024 ->
	stage_write1(Con,0, Bin).
% Stage will write at most 256KB at once. This way we do not block scheduler for too long.
% Data is not written to disk with this call.
% stage_write compresses it to a buffer attached to the connection. 
% If compression not set it just remembers the binary and does no copying (unless small).
stage_write1(Con,Offset,Bin) when byte_size(Bin) > Offset ->
	NWritten = aqdrv_nif:stage_data(Con, Bin, Offset),
	stage_write1(Con, Offset + NWritten, Bin);
stage_write1(_,_,_) ->
	ok.

% Finish compression.
stage_flush({aqdrv,Con}) ->
	aqdrv_nif:stage_flush(Con).

% Write to disk. 
write({aqdrv,Con}, [_|_] = ReplData, [_|_] = Header) ->
	Ref = make_ref(),
	case aqdrv_nif:write(Ref, self(),Con, ReplData, Header) of
		again ->
			% erlang:yield(),
			timer:sleep(?DELAY),
			write({aqdrv,Con},ReplData, Header);
		ok ->
			receive_answer(Ref)
	end.
inject({aqdrv,Con}, Bin) ->
	Ref = make_ref(),
	case aqdrv_nif:inject(Ref, self(), Con, Bin) of
		again ->
			timer:sleep(?DELAY),
			inject({aqdrv, Con},Bin);
		ok ->
			receive_answer(Ref)
	end.


receive_answer(Ref) ->
	receive
		{Ref, Resp} -> Resp
	end.

