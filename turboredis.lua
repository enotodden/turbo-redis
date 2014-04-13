-- # TurboRedis
--
-- Redis library for Turbo
--

local turbo = require("turbo")
local middleclass =  require("turbo.3rdparty.middleclass")
local ffi = require("ffi")
local yield = coroutine.yield
local task = turbo.async.task

-- Range iterator from http://lua-users.org/wiki/RangeIterator
local function range(from, to, step)
    step = step or 1
    return function(_, lastvalue)
        local nextvalue = lastvalue + step
        if step > 0 and nextvalue <= to or step < 0 and nextvalue >= to or
             step == 0
        then
            return nextvalue
        end
    end, nil, from - step
end

turboredis = {
    -- If purist is set to true
    -- turboredis will not convert key-value pair lists to dicts
    -- and will not convert integer replies from certain commands to
    -- booleans for convenience.
    --
    -- TODO: This should be made a per-connection value to avoid
    -- problems if the user wants to use different modes in the same
    -- application.
    --
    purist = false,
    -- Some aliases for strings used in redis commands
    SORT_DESC = "desc",
    SORT_ASC = "asc",
    SORT_LIMIT = "limit",
    SORT_BY = "by",
    SORT_STORE = "store",
    SORT_GET = "get",
    Z_WITHSCORES = "withscores",
    Z_LIMIT = "limit",
    Z_PLUSINF = "+inf",
    Z_MININF = "-inf"
}

-- List of redis commands to generate functions for
turboredis.COMMANDS = {
    "APPEND",
    "AUTH",
    "BGREWRITEAOF",
    "BGSAVE",
    "BITCOUNT",
    "BITOP AND",
    "BITOP OR",
    "BITOP XOR",
    "BITOP NOT",
    "BLPOP",
    "BRPOP",
    "BRPOPLPUSH",
    "CLIENT KILL",
    "CLIENT LIST", -- FIXME: Should parse this..
    "CLIENT GETNAME",
    "CLIENT SETNAME",
    "CONFIG GET",
    "CONFIG REWRITE",
    "CONFIG SET",
    "CONFIG RESETSTAT",
    "DBSIZE",
    "DEBUG OBJECT",
    "DEBUG SEGFAULT",
    "DECR",
    "DECRBY",
    "DEL",
    "DISCARD",
    "DUMP",
    "ECHO",
    "EVAL",
    "EVALSHA",
    "EXEC",
    "EXISTS",
    "EXPIRE",
    "EXPIREAT",
    "FLUSHALL",
    "FLUSHDB",
    "GET",
    "GETBIT",
    "GETRANGE",
    "GETSET",
    "HDEL",
    "HEXISTS",
    "HGET",
    "HGETALL",
    "HINCRBY",
    "HINCRBYFLOAT",
    "HKEYS",
    "HLEN",
    "HMGET",
    "HMSET",
    "HSET",
    "HSETNX",
    "HVALS",
    "INCR",
    "INCRBY",
    "INCRBYFLOAT",
    "INFO",
    "KEYS",
    "LASTSAVE",
    "LINDEX",
    "LINSERT",
    "LLEN",
    "LPOP",
    "LPUSH",
    "LPUSHX",
    "LRANGE",
    "LREM",
    "LSET",
    "LTRIM",
    "MGET",
    "MIGRATE",
    --| MONITOR (not yet supported)
    "MOVE",
    "MSET",
    "MSETNX",
    "MULTI",
    "OBJECT",
    "PERSIST",
    "PEXPIRE",
    "PEXPIREAT",
    "PING",
    "PSETEX",
    --| PSUBSCRIBE (in turboredis.PUBSUB_COMMANDS)
    --| PUBSUB (divided into the subcommands below)
    "PUBSUB CHANNELS",
    "PUBSUB NUMSUB",
    "PUBSUB NUMPAT",
    "PTTL",
    "PUBLISH",
    --| PUNSUBSCRIBE (in turboredis.PUBSUB_COMMANDS)
    "QUIT",
    "RANDOMKEY",
    "RENAME",
    "RENAMENX",
    "RESTORE",
    "RPOP",
    "RPOPLPUSH",
    "RPUSH",
    "RPUSHX",
    "SADD",
    "SAVE",
    "SCARD",
    "SCRIPT EXISTS",
    "SCRIPT FLUSH",
    "SCRIPT KILL",
    "SCRIPT LOAD",
    "SDIFF",
    "SDIFFSTORE",
    "SELECT",
    "SET",
    "SETBIT",
    "SETEX",
    "SETNX",
    "SETRANGE",
    "SHUTDOWN",
    "SINTER",
    "SINTERSTORE",
    "SISMEMBER",
    "SLAVEOF",
    "SLOWLOG GET",
    "SLOWLOG LEN",
    "SLOWLOG RESET",
    "SMEMBERS",
    "SMOVE",
    "SORT",
    "SPOP",
    "SRANDMEMBER",
    "SREM",
    "STRLEN",
    --| SUBSCRIBE (in turboredis.PUBSUB_COMMANDS)
    "SUNION",
    "SUNIONSTORE",
    "SYNC",
    "TIME",
    "TTL",
    "TYPE",
    --| UNSUBSCRIBE (in turboredis.PUBSUB_COMMANDS)
    "UNWATCH",
    "WATCH",
    "ZADD",
    "ZCARD",
    "ZCOUNT",
    "ZINCRBY",
    "ZINTERSTORE",
    "ZRANGE",
    "ZRANGEBYSCORE",
    "ZRANK",
    "ZREM",
    "ZREMRANGEBYRANK",
    "ZREMRANGEBYSCORE",
    "ZREVRANGE",
    "ZREVRANGEBYSCORE",
    "ZREVRANK",
    "ZSCORE",
    "ZUNIONSTORE",
    "SCAN",
    "SSCAN",
    "HSCAN",
    "ZSCAN"
}

-- Convert a table of command+arguments to redis format.
function turboredis.pack(t)
    local out = "*" .. tostring(#t) .. "\r\n"
    for _, v in ipairs(t) do
        out = out .. "$" .. tostring(string.len(v)) .. "\r\n" .. v .. "\r\n"
    end
    return out
end

-- Convert a list of key value pairs ({key, value, key, value, ...})
-- to a table of key value pairs ({key=value, key=value, ...})
function turboredis.from_kvlist(inp)
    local out={}
    local o = false
    for i, v in ipairs(inp) do
        if o then
            out[inp[i-1]] = v
        end
        o = not o
    end
    return out
end

-- Flatten a table
function turboredis.flatten(t)
    if type(t) ~= "table" then return {t} end
    local flat_t = {}
    for _, elem in ipairs(t) do
        for _, val in ipairs(turboredis.flatten(elem)) do
            flat_t[#flat_t + 1] = val
        end
    end
    return flat_t
end

--## Redis protocol helpers

-- Read a redis array reply.
-- Calls `turboredis.read_resp_reply()` on each element.
function turboredis.read_resp_array_reply(stream, n, callback, callback_arg)
    turbo.ioloop.instance():add_callback(function ()
        local out = {}
        local i = 0
        while i < n do
            out[#out+1] = yield(task(turboredis.read_resp_reply, stream, false))
            i = i + 1
        end
        if callback_arg then
            callback(callback_arg, out)
        else
            callback(out)
        end
    end)
end

-- Read a Redis reply
function turboredis.read_resp_reply (stream, wrap, callback, callback_arg)
    turbo.ioloop.instance():add_callback(function ()
        local part
        local first
        local len
        local data
        local is_ss = false

        --> Read the first line of the reply to figure out
        --> reply type and length.
        part = yield(task(stream.read_until, stream, "\r\n"))
        first = part:sub(1,1)

        --> Handle a 'simple string' or error reply.
        if first == "+" or first == "-" then
            is_ss = true
            res = {first == "+", part:sub(2, part:len()-2)}
        --> Handle a 'bulk string' reply.
        elseif first == "$" then
            len = tonumber(part:sub(2, part:len()-2))
            if len == -1 then
                res = nil
            else
                data = yield(task(stream.read_bytes, stream, len+2))
                res = data:sub(1, data:len()-2)
            end
        --> Handle an array reply, we call turboredis.read_resp_array_reply
        --> if the length is not -1 (nil)
        elseif first == "*" then
            len = tonumber(part:sub(2, part:len()-2))
            if len == -1 then
                res = nil
            else
                res = yield(task(turboredis.read_resp_array_reply, stream, len))
            end
        --> Handle an integer reply
        elseif first == ":" then
            res = tonumber(part:sub(2, part:len()-2))
        else
            --> Should never get here, but if we do, we fail in
            --> the same way as with an error reply.
            res = {false, "turboredis: Error in reply from redis"}
        end
        if (not is_ss) and wrap then
            --> Wrap result in a table if not a 'simple string' or 'error' reply
            res = {res}
        end
        if callback_arg then
            callback(callback_arg, res)
        else
            callback(res)
        end
    end)
end


--## Command
--
-- Created with the IOStream instance of the `Connection`
--

turboredis.Command = class("Command")
function turboredis.Command:initialize(cmd, stream)
    self.ioloop = turbo.ioloop.instance()
    self.cmd = cmd
    self.cmdstr = turboredis.pack(cmd)
    self.stream = stream
end

-- Format reply from Redis for convenience
--
--> NOTE: This is not consistent and needs some work
function turboredis.Command:_format_res(res)
    local out = res
    if not turboredis.purist then
        if self.cmd[1] == "CONFIG" then
            if self.cmd[2] == "GET" then
                out = {turboredis.from_kvlist(res[1])}
            end
        elseif self.cmd[1] == "INCRBYFLOAT" or
               self.cmd[1] == "PTTL" then
            out = {tonumber(res[1])}
        elseif self.cmd[1] == "PUBSUB" then
            if self.cmd[2] == "NUMSUB" then
                out = {}
                for i in range(1, #res[1], 2) do
                    out[res[1][i]] = tonumber(res[1][i+1])
                end
                return {out}
            end
        elseif self.cmd[1] == "HGETALL" then
            out = {turboredis.from_kvlist(res)}
        else
            for _, c in ipairs({"EXISTS", "EXPIRE",
                                "EXPIREAT", "HEXISTS",
                                "HSETNX", "MSETNX",
                                "MOVE", "RENAMENX", "SETNX",
                                "SISMEMBER", "SMOVE"}) do
                if self.cmd[1] == c then
                    out = {res[1] == 1}
                    return out
                end
            end
        end
    end
    return out
end

-- Handle a reply from Redis.
--
-- Calls `_format_res` to format the reply and then the callback passed to
-- `:execute()`
--
function turboredis.Command:_handle_reply(res)
    res = self:_format_res(res)
    if self.callback_arg then
        self.callback(self.callback_arg, unpack(res))
    else
        self.callback(unpack(res))
    end
end

function turboredis.Command:execute(callback, callback_arg)
    self.callback = callback
    self.callback_arg = callback_arg
    self.stream:write(self.cmdstr, function()
        turboredis.read_resp_reply(self.stream, true, self._handle_reply, self)
    end)
end

-- Execute the command, but unlike `:execute()` we don't try to
-- read a reply.
--
-- This is useful for `SUBSCRIBE/UNSUBSCRIBE` commands which 'replies'
-- through PubSub messages.
--
function turboredis.Command:execute_noreply(callback, callback_arg)
    self.stream:write(self.cmdstr, function()
        if callback_arg then
            callback(callback_arg, true)
        else
            callback(true)
        end
    end)
end


--## Connection
--
-- The main class that handles connecting and issuing commands.

turboredis.Connection = class("Connection")
function turboredis.Connection:initialize(host, port, kwargs)
    kwargs = kwargs or {}
    self.host = host or "127.0.0.1"
    self.port = port or 6379
    self.family = 2
    self.ioloop = kwargs.ioloop or turbo.ioloop.instance()
    self.connect_timeout = kwargs.connect_timeout or 5
end

function turboredis.Connection:_connect_done(args)
    self.connect_timeout_ref = nil
    self.connect_coctx:set_state(turbo.coctx.states.DEAD)
    self.connect_coctx:set_arguments(args)
    self.connect_coctx:finalize_context()
end

function turboredis.Connection:_handle_connect_timeout()
    self:_connect_done({false, {err=-1, msg="Connect timeout"}})
end

function turboredis.Connection:_handle_connect_error(err, strerror)
    self.ioloop:remove_timeout(self.connect_timeout_ref)
    self:_connect_done({false, {err=err, msg=strerror}})
end

function turboredis.Connection:_handle_connect()
    self.ioloop:remove_timeout(self.connect_timeout_ref)
    self:_connect_done({true})
end

-- Connect to Redis
--
-- FIXME: This works but looks like sh*t and needs to be re-worked
function turboredis.Connection:connect(timeout, callback, callback_arg)
    local timeout
    local connect_timeout_ref
    local ctx

    if not callback then
        ctx = turbo.coctx.CoroutineContext:new(self.ioloop)
        ctx:set_state(turbo.coctx.states.WORKING)
    end

    local connect_done = function(a1, a2)
        if callback then
            if callback_arg then
                callback(callback_arg, a1, a2)
            else
                callback(a1, a2)
            end
        else
            ctx:set_state(turbo.coctx.states.DEAD)
            ctx:set_arguments({a1, a2})
            ctx:finalize_context()
        end
    end

    function handle_connect()
        self.ioloop:remove_timeout(self.connect_timeout_ref)
        connect_done(true)
    end

    function handle_connect_timeout()
        connect_done(false, {err=-1, msg="Connect timeout"})
    end

    function handle_connect_error(err, strerror)
        self.ioloop:remove_timeout(self.connect_timeout_ref)
        connect_done(false, {err=err, msg=strerror})
    end

    self.ioloop = turbo.ioloop.instance()
    timeout = (timeout or self.connect_timeout) * 1000 +
              turbo.util.gettimeofday()
    connect_timeout_ref = self.ioloop:add_timeout(timeout,
                                                   handle_connect_timeout)
    self.sock, msg = turbo.socket.new_nonblock_socket(self.family,
                                                      turbo.socket.SOCK_STREAM,
                                                      0)
    self.stream = turbo.iostream.IOStream:new(self.sock, self.ioloop)
    local rc, msg = self.stream:connect(self.host,
                                          self.port,
                                          self.family,
                                          handle_connect,
                                          handle_connect_error,
                                          self)
    if rc ~= 0 then
        error("Connect failed")
        handle_connect_error(-1, "Connect failed")
        return -1 --wtf
    end

    if not callback then
        ctx:set_state(turbo.coctx.states.WAIT_COND)
        return ctx
    end
end

-- Create a new `Command` and run it.
function turboredis.Connection:run(cmd, callback, callback_arg)
    return turboredis.Command:new(cmd, self.stream):execute(callback,
                                                            callback_arg)
end

-- Run a command without reading the a reply
function turboredis.Connection:run_noreply(cmd, callback, callback_arg)
    return turboredis.Command:new(cmd, self.stream):execute_noreply(callback,
        callback_arg)
end

function turboredis.Connection:run_mod(cmd, mod, callback, callback_arg)
    turboredis.Command:new(cmd, self.stream):execute(function (...)
        local args = mod(unpack({...}))
        if callback_arg then
            table.insert(args, 1, callback_arg)
            callback(unpack(args))
        else
            callback(unpack(args))
        end
    end)
end

-- ####Dual callback/yield interface.
--
-- If the user has not supplied a callback
-- we use a `turbo.async.task`.
--
-- This allows all commands to be called like:
-- |>>>
--      r = yield(con:get("foo"))
-- <<<|
-- or with a callback, like:
-- |>>>
--      con.get("foo", function (r)
--          print(r)
--      end)
-- <<<|
--
function turboredis.Connection:run_dual(cmd, callback, callback_arg)
    if callback then
        return self:run(cmd, callback, callback_arg)
    else
        return task(self.run, self, cmd)
    end
end

-- The same as `run_dual()`, except that it takes the `mod` argument
-- and passes it on to `run_mod()`
function turboredis.Connection:run_mod_dual(cmd, mod, callback, callback_arg)
    if callback then
        return self:run_mod(cmd, mod, callback, callback_arg)
    else
        return task(self.run_mod, self, cmd, mod)
    end
end


-- Dynamically generate functions for all commands in `turboredis.COMMANDS`
--
-- This applies to all normal commands except for `CONFIG GET` and
-- `SUBSCRIBE/UNSUBSCRIBE` pubsub commands.
--
for _, v in ipairs(turboredis.COMMANDS) do
    turboredis.Connection[v:lower():gsub(" ", "_")] = function (self, ...)
        local cmd = turboredis.flatten({v:split(" "), ...})
        local callback = false
        local callback_arg = nil
        if type(cmd[#cmd]) == "function" then
            callback = cmd[#cmd]
            cmd[#cmd] = nil
        elseif type(cmd[#cmd-1]) == "function" then
            callback = cmd[#cmd-1]
            callback_arg = cmd[#cmd]
            cmd[#cmd-1] = nil
            cmd[#cmd] = nil
        end

        if callback then
            return self:run(cmd, callback, callback_arg)
        else
            return task(self.run, self, cmd)
        end
    end
end

function turboredis.Connection:config_get(key, callback, callback_arg)
    return self:run_mod_dual({"CONFIG", "GET", key}, function(v)
        return {v[key]}
    end)
end


--## PUBSUB

turboredis.PUBSUB_COMMANDS = {
    "SUBSCRIBE",
    "PSUBSCRIBE",
    "PUNSUBSCRIBE",
    "UNSUBSCRIBE"
}

turboredis.PubSubConnection = class("PubSubConnection", turboredis.Connection)

function turboredis.PubSubConnection:read_msg(callback, callback_arg)
    turboredis.read_resp_reply(self.stream, false, callback, callback_arg)
end

function turboredis.PubSubConnection:start(callback, callback_arg)
    self.callback = callback
    self.callback_arg = callback_arg
    turbo.ioloop.instance():add_callback(function ()
        while true do
            local msg = yield(task(self.read_msg, self))
            local res = {}
            res.msgtype = msg[1]
            if res.msgtype == "psubscribe" then
                res.pattern = msg[2]
                res.channel = nil
                res.data = msg[3]
            elseif res.msgtype == "punsubscribe" then
                res.pattern = msg[2]
                res.channel = nil
                res.data = msg[3]
            elseif res.msgtype == "pmessage" then
                res.pattern = msg[2]
                res.channel = msg[3]
                res.data = msg[4]
            else
                res.pattern = nil
                res.channel = msg[2]
                res.data = msg[3]
            end
            if self.callback_arg then
                self.callback(callback_arg, res)
            else
                self.callback(res)
            end
        end
    end)
end

for _, v in ipairs(turboredis.PUBSUB_COMMANDS) do
    turboredis.PubSubConnection[v:lower():gsub(" ", "_")] = function (self, ...)
        local cmd = turboredis.flatten({v:split(" "), ...})
        local callback = false
        local callback_arg = nil
        if type(cmd[#cmd]) == "function" then
            callback = cmd[#cmd]
            cmd[#cmd] = nil
        elseif type(cmd[#cmd-1]) == "function" then
            callback = cmd[#cmd-1]
            callback_arg = cmd[#cmd]
            cmd[#cmd-1] = nil
            cmd[#cmd] = nil
        end
        if callback then
            return self:run_noreply(cmd, callback, callback_arg)
        else
            return task(self.run_noreply, self, cmd)
        end
    end
end

return turboredis
