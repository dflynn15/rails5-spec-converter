require 'rails5/spec_converter/node_textifier'

class HashRewriter
  # technically format is special
  ALLOWED_KWARG_KEYS = %i(params session flash method body xhr format)

  attr_reader :hash_node, :original_indent

  def initialize(content:, hash_node:, original_indent:, options:)
    @options = options
    @content = content
    @hash_node = hash_node
    @original_indent = original_indent
    @textifier = NodeTextifier.new(@content)
    partition_params(@hash_node)
  end

  def rewritten_params_hash
    return if @pairs_that_belong_in_params.length == 0

    joiner = joiner_between_pairs(hash_node)
    rewritten_hashes = []

    if multiline?(hash_node)
      params_hash = appropriately_indented_params_hash(
        hash_node: hash_node,
        pairs: @pairs_that_belong_in_params
      )
      rewritten_hashes << "params: #{params_hash}"
    else
      curly_sep = determine_curly_sep(hash_node)
      rewritten_hashes << "params: {#{curly_sep}#{restring_hash(@pairs_that_belong_in_params)}#{curly_sep}}"
    end

    if @pairs_that_belong_outside_params.length > 0
      rewritten_hashes << restring_hash(
        @pairs_that_belong_outside_params,
        joiner: joiner
      )
    end

    rewritten_hashes.join(joiner)
  end

  def should_rewrite_hash?
    @pairs_that_belong_in_params.length > 0
  end

  private

  def partition_params(hash_node)
    @pairs_that_belong_in_params = []
    @pairs_that_belong_outside_params = []

    hash_node.children.each do |pair|
      key = pair.children[0].children[0]

      if ALLOWED_KWARG_KEYS.include?(key)
        @pairs_that_belong_outside_params << pair
      else
        @pairs_that_belong_in_params << pair
      end
    end
  end

  def has_trailing_comma?(hash_node)
    @textifier.text_after_last_pair(hash_node) =~ /,/
  end

  def indent_before_first_pair(hash_node)
    return nil unless hash_node.children.length > 0

    extract_indent(@textifier.text_before_first_pair(hash_node))
  end

  def indent_after_last_pair(hash_node)
    return nil unless hash_node.children.length > 0

    extract_indent(@textifier.text_after_last_pair(hash_node))
  end

  def multiline?(hash_node)
    @textifier.node_to_string(hash_node).include?("\n")
  end

  def indent_of_first_value_if_multiline(hash_node)
    return nil if hash_node.children.length == 0
    return nil unless hash_node.children[0].pair_type?

    first_value = hash_node.children[0].children[1]
    return nil unless first_value.hash_type? || first_value.array_type?
    value_str_lines = @textifier.node_to_string(first_value).split("\n")
    return nil if value_str_lines.length == 1
    return nil unless value_str_lines[0].match(/[\s\[{]/)

    value_str_lines[1].match(/^(\s*)/)[1].sub(original_indent, '')
  end

  def additional_indent(hash_node)
    return nil if indent_before_first_pair(hash_node)

    joiner = joiner_between_pairs(hash_node)
    joiner && joiner.include?("\n") ? @options.indent : nil
  end

  def existing_indent(hash_node)
    text_before_hash = @textifier.text_before_node(hash_node)
    whitespace_indent = extract_indent(text_before_hash)
    return whitespace_indent if whitespace_indent

    return indent_before_first_pair(hash_node) if indent_before_first_pair(hash_node)

    joiner = joiner_between_pairs(hash_node)
    extract_indent(joiner) || ''
  end

  def no_space_after_curly?(hash_node)
    hash_node.parent.loc.expression.source.match(/{\S/)
  end

  def joiner_between_pairs(hash_node)
    texts_between = []
    hash_node.children[0..-2].each_with_index do |pair, index|
      next_pair = hash_node.children[index + 1]
      texts_between << @textifier.text_between_siblings(pair, next_pair)
    end
    if texts_between.uniq.length > 1
      log "Inconsistent whitespace between hash pairs, using the first separator (#{texts_between[0].inspect})."
      log "Seen when processing this expression: \n```\n#{hash_node.loc.expression.source}\n```\n\n"
    end
    texts_between[0]
  end

  def appropriately_indented_params_hash(hash_node:, pairs:)
    outer_indent = existing_indent(hash_node)
    middle_indent = indent_of_first_value_if_multiline(hash_node)
    inner_indent = additional_indent(hash_node)

    restrung_hash = restring_hash(
      pairs,
      indent: outer_indent + (inner_indent || ''),
      joiner: ",\n"
    )
    if middle_indent
      restrung_hash = original_indent + add_indent(restrung_hash, middle_indent)
    end
    final_brace_indent = if middle_indent
                           original_indent
                         else
                           indent_after_last_pair(hash_node) || outer_indent
                         end
    "{\n#{restrung_hash}\n#{final_brace_indent}}"
  end

  def determine_curly_sep(hash_node)
    return ' ' if @options.hash_spacing == true
    return '' if @options.hash_spacing == false

    no_space_after_curly?(hash_node) ? '' : ' '
  end

  def restring_hash(pairs, joiner: ", ", indent: '')
    hash_string = pairs.map { |pair| "#{indent}#{pair.loc.expression.source}" }.join(joiner)
    if has_trailing_comma?(hash_node)
      hash_string + ','
    else
      hash_string
    end
  end

  def add_indent(str, indent)
    str.split("\n").map { |line| indent + line }.join("\n")
  end

  def extract_indent(str)
    return unless str

    match = str.match("\n(\s*)")
    match[1] if match
  end
end