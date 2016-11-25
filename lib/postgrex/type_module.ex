defmodule Postgrex.TypeModule do
  alias Postgrex.Types
  alias Postgrex.TypeInfo

  def define(module, parameters, type_infos, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:decode_binary, :copy)
      |> Keyword.put_new(:date, :postgrex)
    {type_infos, config} = associate(parameters, type_infos, opts)
    null = Keyword.get(opts, :null)
    define_inline(module, type_infos, config, null)
  end

  def write(file, module, parameters, type_infos, opts \\ []) do
    File.write(file, generate(module, parameters, type_infos, opts))
  end

  ## Helpers

  defp directives(config) do
    requires =
      for {extension, _} <- config do
        quote do: require unquote(extension)
      end

    quote do
      import Postgrex.BinaryUtils, [warn: false]

      unquote(requires)
    end
  end

  defp attributes(null) do
    quote do
      @compile :bin_opt_info
      @null unquote(null)
    end
  end

  defp fetch(type_infos) do
    fetches =
      for {%TypeInfo{oid: oid}, info} <- type_infos do
        case info do
          {format, type} ->
            quote do
              def fetch(unquote(oid)) do
                {:ok, {unquote(format), unquote(Macro.escape(type))}}
              end
            end
          nil ->
            quote do
              def fetch(unquote(oid)), do: :error
            end
        end
      end

    quote do
      unquote(fetches)
      def fetch(_), do: {:error, nil}
    end
  end

  defp rewrite(ast, [{:->, meta, _} | _original]) do
    location = [file: meta[:file] || "nofile", line: meta[:keep] || 1]

    Macro.prewalk(ast, fn
      {left, meta, right} ->
        {left, location ++ meta, right}
      other ->
        other
    end)
  end

  defp encode(config, null) do
    encodes =
      for {extension, {opts, [_|_], format}} <- config do
        encode = extension.encode(opts)

        clauses =
          for clause <- encode do
            encode_type(extension, format, clause)
          end

        clauses = [encode_null(extension, format, null) | clauses]

        quote do
          unquote(encode_value(extension, format))

          unquote(encode_params(extension, format))

          unquote(encode_tuple(extension, format))

          unquote(encode_inline(extension, format))

          unquote(clauses |> rewrite(encode))
        end
      end

    quote do
      def encode_params(params, types) do
        encode_params(params, types, [])
      end

      def encode_tuple(tuple, oids, types) do
        encode_tuple(tuple, 1, oids, types, [])
      end

      unquote(encodes)

      defp encode_params([], [], encoded), do: Enum.reverse(encoded)
      defp encode_params(params, _, _) when is_list(params), do: :error

      defp encode_tuple(tuple, n, [], [], acc) when tuple_size(tuple) < n do
        acc
      end
      defp encode_tuple(tuple, _, [], [], _) when is_tuple(tuple), do: :error

      def encode_list(list, type) do
        encode_list(list, type, [])
      end

      defp encode_list([value | rest], type, acc) do
        encode_list(rest, type, [acc | encode_value(value, type)])
      end
      defp encode_list([], _, acc) do
        acc
      end
    end
  end

  defp encode_type(extension, :super_binary, clause) do
    encode_super(extension, clause)
  end
  defp encode_type(extension, _, clause) do
    encode_extension(extension, clause)
  end

  defp encode_extension(extension, clause) do
    case split_extension(clause) do
      {pattern, guard, body} ->
        encode_extension(extension, pattern, guard, body)
      {pattern, body} ->
        encode_extension(extension, pattern, body)
    end
  end

  defp encode_extension(extension, pattern, guard, body) do
    quote do
      defp unquote(extension)(unquote(pattern)) when unquote(guard) do
        unquote(body)
      end
    end
  end

  defp encode_extension(extension, pattern, body) do
    quote do
      defp unquote(extension)(unquote(pattern)) do
        unquote(body)
      end
    end
  end

  defp encode_super(extension, clause) do
    case split_super(clause) do
      {pattern, sub_oids, sub_types, guard, body} ->
        encode_super(extension, pattern, sub_oids, sub_types, guard, body)
      {pattern, sub_oids, sub_types, body} ->
        encode_super(extension, pattern, sub_oids, sub_types, body)
    end
  end

  defp encode_super(extension, pattern, sub_oids, sub_types, guard, body) do
    quote do
      defp unquote(extension)(unquote(pattern), unquote(sub_oids),
                              unquote(sub_types)) when unquote(guard) do
        unquote(body)
      end
    end
  end

  defp encode_super(extension, pattern, sub_oids, sub_types, body) do
    quote do
      defp unquote(extension)(unquote(pattern),
                              unquote(sub_oids), unquote(sub_types)) do
        unquote(body)
      end
    end
  end

  defp encode_null(extension, :super_binary, null) do
    quote do
      defp unquote(extension)(unquote(null), _sub_oids, _sub_types) do
        unquote(null)
      end
    end
  end
  defp encode_null(extension, _, null) do
    quote do
      defp unquote(extension)(unquote(null)), do: unquote(null)
    end
  end

  defp encode_inline(extension, :super_binary) do
    quote do
      @compile {:inline, [{unquote(extension), 3}]}
    end
  end
  defp encode_inline(extension, _) do
    quote do
      @compile {:inline, [{unquote(extension), 1}]}
    end
  end

  defp encode_value(extension, :super_binary) do
    quote do
      def encode_value(value, {unquote(extension), sub_oids, sub_types}) do
        unquote(extension)(value, sub_oids, sub_types)
      end
    end
  end
  defp encode_value(extension, _) do
    quote do
      def encode_value(value, unquote(extension)) do
        unquote(extension)(value)
      end
    end
  end

  defp encode_params(extension, :super_binary) do
    quote do
      defp encode_params([param | params],
                         [{unquote(extension), sub_oids, sub_types} | types],
                         acc) do
        encoded = unquote(extension)(param, sub_oids, sub_types)
        encode_params(params, types, [encoded | acc])
      end
    end
  end
  defp encode_params(extension, _) do
    quote do
      defp encode_params([param | params], [unquote(extension) | types], acc) do
        encoded = unquote(extension)(param)
        encode_params(params, types, [encoded | acc])
      end
    end
  end

  defp encode_tuple(extension, :super_binary) do
    quote do
      defp encode_tuple(tuple, n, [oid | oids],
                        [{unquote(extension), sub_oids, sub_types} | types],
                        acc) do
        param = :erlang.element(n, tuple)
        acc = [acc, <<oid::uint32>> |
                unquote(extension)(param, sub_oids, sub_types)]
        encode_tuple(tuple, n+1, oids, types, acc)
      end
    end
  end
  defp encode_tuple(extension, _) do
    quote do
      defp encode_tuple(tuple, n, [oid | oids],
                        [unquote(extension) | types], acc) do
        param = :erlang.element(n, tuple)
        acc = [acc, <<oid::uint32>> | unquote(extension)(param)]
        encode_tuple(tuple, n+1, oids, types, acc)
      end
    end
  end

  defp decode(config, null) do
    rest = quote do: rest
    acc  = quote do: acc
    oids = quote do: oids
    n    = quote do: n

    row_dispatch =
      for {extension, {_, [_|_], format}} <- config do
        decode_row_dispatch(extension, format, rest, acc)
      end

    decoded  = (quote do: ([] -> decoded_row(unquote(rest), unquote(acc))))
    row_dispatch = row_dispatch ++ decoded

    tuple_dispatch =
       for {extension, {_, [_|_], format}} <- config do
         decode_tuple_dispatch(extension, format, rest, oids, n, acc)
       end

    decodes =
      for {extension, {opts, [_|_], format}} <- config do
        decode = extension.decode(opts)

        clauses =
          for clause <- decode do
            decode_type(extension, format, clause, row_dispatch, rest, acc)
          end

        quote do
          unquote(decode_list(extension, format))

          unquote(clauses |> rewrite(decode))

          unquote(decode_null(extension, format, row_dispatch, rest, null, acc))
        end
      end

    quote do
      def decode_row(<<unquote(rest)::binary>>, types) do
        unquote(acc) = []
        case types do
          unquote(row_dispatch)
        end
      end

      def decode_tuple(<<unquote(rest)::binary>>, oids, types) do
        decode_tuple(rest, oids, types, 0, [])
      end

      defp decode_tuple(<<oid::int32, unquote(rest)::binary>>,
                        [oid | unquote(oids)], types,
                        unquote(n), unquote(acc)) do
        case types do
          unquote(tuple_dispatch)
        end
      end
      defp decode_tuple(<<>>, [], [], n, acc) do
        :erlang.make_tuple(n, unquote(null), acc)
      end

      unquote(decodes)

      defp decoded_row(<<_::binary-size(0)>>, acc), do: acc
    end
  end

  defp decode_row_dispatch(extension, :super_binary, rest, acc) do
    [clause] =
      quote do
        [{unquote(extension), sub_oids, sub_types} | types] ->
          unquote(extension)(unquote(rest), sub_oids, sub_types,
                             types, unquote(acc))
      end
    clause
  end
  defp decode_row_dispatch(extension, _, rest, acc) do
    [clause] =
      quote do
        [unquote(extension) | types] ->
          unquote(extension)(unquote(rest), types, unquote(acc))
      end
    clause
  end

  defp decode_tuple_dispatch(extension, :super_binary, rest, oids, n, acc) do
    [clause] =
      quote do
        [{unquote(extension), sub_oids, sub_types} | types] ->
          unquote(extension)(unquote(rest), sub_oids, sub_types,
                             unquote(oids), types, unquote(n)+1, unquote(acc))
      end
    clause
  end
  defp decode_tuple_dispatch(extension, _, rest, oids, n, acc) do
    [clause] =
      quote do
        [unquote(extension) | types] ->
          unquote(extension)(unquote(rest), unquote(oids), types,
                             unquote(n)+1, unquote(acc))
      end
    clause
  end

  defp decode_type(extension, :super_binary, clause, dispatch, rest, acc) do
    decode_super(extension, clause, dispatch, rest, acc)
  end
  defp decode_type(extension, _, clause, dispatch, rest, acc) do
    decode_extension(extension, clause, dispatch, rest, acc)
  end

  defp decode_list(extension, :super_binary) do
    quote do
      def decode_list(data, {unquote(extension), sub_oids, sub_types}) do
        unquote(extension)(data, sub_oids, sub_types, [])
      end
    end
  end
  defp decode_list(extension, _) do
    quote do
      def decode_list(data, unquote(extension)) do
        unquote(extension)(data, [])
      end
    end
  end

  defp decode_null(extension, :super_binary, dispatch, rest, null, acc) do
    decode_super_null(extension, dispatch, rest, null, acc)
  end
  defp decode_null(extension, _, dispatch, rest, null, acc) do
    decode_extension_null(extension, dispatch, rest, null, acc)
  end

  defp decode_extension(extension, clause, dispatch, rest, acc) do
    case split_extension(clause) do
      {pattern, guard, body} ->
        decode_extension(extension, pattern, guard, body, dispatch, rest, acc)
      {pattern, body} ->
        decode_extension(extension, pattern, body, dispatch, rest, acc)
    end
  end

  defp decode_extension(extension, pattern, guard, body, dispatch, rest, acc) do
    quote do
      defp unquote(extension)(<<unquote(pattern), unquote(rest)::binary>>,
                              types, acc) when unquote(guard) do
        unquote(acc) = [unquote(body) | acc]
        case types do
          unquote(dispatch)
        end
      end

      defp unquote(extension)(<<unquote(pattern), rest::binary>>, acc)
                              when unquote(guard) do
        decoded = unquote(body)
        unquote(extension)(rest, [decoded | acc])
      end

      defp unquote(extension)(<<unquote(pattern), unquote(rest)::binary>>,
                              oids, types, n, acc) when unquote(guard) do
        unquote(acc) = [{n, unquote(body)} | acc]
        decode_tuple(unquote(rest), oids, types, n, unquote(acc))
      end
    end
  end

  defp decode_extension(extension, pattern, body, dispatch, rest, acc) do
    quote do
      defp unquote(extension)(<<unquote(pattern), unquote(rest)::binary>>,
                              types, acc) do
        unquote(acc) = [unquote(body) | acc]
        case types do
          unquote(dispatch)
        end
      end

      defp unquote(extension)(<<unquote(pattern), rest::binary>>, acc) do
        decoded = unquote(body)
        unquote(extension)(rest, [decoded | acc])
      end

      defp unquote(extension)(<<unquote(pattern), rest::binary>>,
                              oids, types, n, acc) do
        decode_tuple(rest, oids, types, n, [{n, unquote(body)} | acc])
      end
    end
  end

  defp decode_extension_null(extension, dispatch, rest, null, acc) do
    quote do
      defp unquote(extension)(<<-1::int32, unquote(rest)::binary>>,
                              types, acc) do
        unquote(acc) = [unquote(null) | acc]
        case types do
          unquote(dispatch)
        end
      end

      defp unquote(extension)(<<-1::int32, rest::binary>>, acc) do
        unquote(extension)(rest, [unquote(null) | acc])
      end

      defp unquote(extension)(<<>>, acc) do
        acc
      end

      defp unquote(extension)(<<-1::int32, rest::binary>>,
                              oids, types, n, acc) do
        decode_tuple(rest, oids, types, n, acc)
      end
    end
  end

  defp split_extension({:->, _, [head, body]}) do
    case head do
      [{:when, _, [pattern, guard]}] ->
        {pattern, guard, body}
      [pattern] ->
        {pattern, body}
    end
  end

  defp decode_super(extension, clause, dispatch, rest, acc) do
    case split_super(clause) do
      {pattern, oids, types, guard, body} ->
        decode_super(extension, pattern, oids, types, guard, body, dispatch,
                     rest, acc)
      {pattern, oids, types, body} ->
        decode_super(extension, pattern, oids, types, body, dispatch, rest, acc)
    end
  end

  defp decode_super(extension, pattern, sub_oids, sub_types, guard, body,
                    dispatch, rest, acc) do
    quote do
      defp unquote(extension)(<<unquote(pattern), unquote(rest)::binary>>,
                              unquote(sub_oids), unquote(sub_types),
                              types, acc) when unquote(guard) do
        unquote(acc) = [unquote(body) | acc]
        case types do
          unquote(dispatch)
        end
      end

      defp unquote(extension)(<<unquote(pattern), rest::binary>>,
                              unquote(sub_oids), unquote(sub_types), acc)
           when unquote(guard) do
        decoded = unquote(body)
        unquote(extension)(rest, unquote(sub_oids), unquote(sub_types),
                           [decoded | acc])
      end

      defp unquote(extension)(<<unquote(pattern), unquote(rest)::binary>>,
                              unquote(sub_oids), unquote(sub_types),
                              oids, types, n, acc) when unquote(guard) do
        decode_tuple(unquote(rest), oids, types, n, [{n, unquote(body)} | acc])
      end
    end
  end

  defp decode_super(extension, pattern, sub_oids, sub_types, body, dispatch,
                    rest, acc) do
    quote do
      defp unquote(extension)(<<unquote(pattern), unquote(rest)::binary>>,
                              unquote(sub_oids), unquote(sub_types),
                              types, acc) do
        unquote(acc) = [unquote(body) | acc]
        case types do
          unquote(dispatch)
        end
      end

      defp unquote(extension)(<<unquote(pattern), rest::binary>>,
                              unquote(sub_oids), unquote(sub_types), acc) do
        decoded = unquote(body)
        unquote(extension)(rest, unquote(sub_oids), unquote(sub_types),
                           [decoded | acc])
      end

      defp unquote(extension)(<<unquote(pattern), unquote(rest)::binary>>,
                              unquote(sub_oids), unquote(sub_types),
                              oids, types, n, acc) do
        unquote(acc) = [{n, unquote(body)} | acc]
        decode_tuple(unquote(rest), oids, types, n, unquote(acc))
      end
    end
  end

  defp decode_super_null(extension, dispatch, rest, null, acc) do
    quote do
      defp unquote(extension)(<<-1::int32, unquote(rest)::binary>>,
                              _sub_oids, _sub_types, types, acc) do
        unquote(acc) = [unquote(null) | acc]
        case types do
          unquote(dispatch)
        end
      end

      defp unquote(extension)(<<-1::int32, rest::binary>>,
                              sub_oids, sub_types, acc) do
        acc = [unquote(null) | acc]
        unquote(extension)(rest, sub_oids, sub_types, acc)
      end

      defp unquote(extension)(<<>>, _sub_oid, _sub_types, acc) do
        acc
      end

      defp unquote(extension)(<<-1::int32, rest::binary>>,
                              _sub_oids, _sub_types,
                              oids, types, n, acc) do
        decode_tuple(rest, oids, types, n, acc)
      end
    end
  end

  defp split_super({:->, _, [head, body]}) do
    case head do
      [{:when, _, [pattern, sub_oids, sub_types, guard]}] ->
        {pattern, sub_oids, sub_types, guard, body}
      [pattern, sub_oids, sub_types] ->
        {pattern, sub_oids, sub_types, body}
    end
  end

  defp associate(parameters, type_infos, opts) do
    extension_args = Postgrex.Utils.default_extensions(opts)
    extensions = Enum.map(extension_args, &elem(&1, 0))
    config = Types.configure(extension_args, parameters)
    {Types.associate_type_infos(type_infos, extensions, config), config}
  end

  defp define_inline(module, type_infos, config, null) do
    quoted = [directives(config), attributes(null), fetch(type_infos),
              encode(config, null), decode(config, null)]
    Module.create(module, quoted, Macro.Env.location(__ENV__))
  end

  defp generate(module, parameters, types, opts) do
    ["parameters =\n",
     gen_inspect(parameters), ?\n,
     "types =\n",
     gen_inspect(types), ?\n,
     gen_inspect(__MODULE__),
      ".define(#{gen_inspect(module)}, parameters, types, ",
      gen_inspect(opts), ")\n"]
  end

  defp gen_inspect(term) do
    inspect(term, [limit: :infinity, width: 80, pretty: true])
  end
end