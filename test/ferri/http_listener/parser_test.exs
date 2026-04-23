defmodule Ferri.HttpListener.ParserTest do
  use ExUnit.Case, async: true

  alias Ferri.HttpListener.Parser

  describe "headers_complete?/1" do
    test "false for empty buffer" do
      refute Parser.headers_complete?("")
    end

    test "false when terminator is absent" do
      refute Parser.headers_complete?("GET / HTTP/1.1\r\nHost: foo.example\r\n")
    end

    test "true when buffer ends with the terminator" do
      assert Parser.headers_complete?("GET / HTTP/1.1\r\nHost: foo.example\r\n\r\n")
    end

    test "true when buffer contains the terminator plus a body" do
      assert Parser.headers_complete?("POST / HTTP/1.1\r\nHost: x\r\n\r\nhello=world")
    end

    test "false for a partial terminator" do
      refute Parser.headers_complete?("GET / HTTP/1.1\r\nHost: x\r\n\r")
    end

    test "false for short buffers that cannot contain the terminator" do
      refute Parser.headers_complete?("\r\n")
      refute Parser.headers_complete?("abc")
    end
  end

  describe "extract_host/1" do
    test "returns the Host header value" do
      headers = "GET / HTTP/1.1\r\nHost: foo.example.com\r\n\r\n"
      assert Parser.extract_host(headers) == {:ok, "foo.example.com"}
    end

    test "is case-insensitive on the header name" do
      headers = "GET / HTTP/1.1\r\nhOsT: foo.example.com\r\n\r\n"
      assert Parser.extract_host(headers) == {:ok, "foo.example.com"}
    end

    test "strips a trailing :port" do
      headers = "GET / HTTP/1.1\r\nHost: foo.example.com:8080\r\n\r\n"
      assert Parser.extract_host(headers) == {:ok, "foo.example.com"}
    end

    test "trims surrounding whitespace" do
      headers = "GET / HTTP/1.1\r\nHost:    foo.example.com   \r\n\r\n"
      assert Parser.extract_host(headers) == {:ok, "foo.example.com"}
    end

    test "skips non-Host headers and returns the Host one" do
      headers =
        "GET / HTTP/1.1\r\n" <>
          "User-Agent: curl/8.0\r\n" <>
          "Accept: */*\r\n" <>
          "Host: foo.example.com\r\n\r\n"

      assert Parser.extract_host(headers) == {:ok, "foo.example.com"}
    end

    test "returns :error when no Host header is present" do
      headers = "GET / HTTP/1.1\r\nUser-Agent: curl/8.0\r\n\r\n"
      assert Parser.extract_host(headers) == :error
    end

    test "returns :error for an empty binary" do
      assert Parser.extract_host("") == :error
    end

    test "returns the first Host header when duplicated" do
      headers =
        "GET / HTTP/1.1\r\n" <>
          "Host: first.example\r\n" <>
          "Host: second.example\r\n\r\n"

      assert Parser.extract_host(headers) == {:ok, "first.example"}
    end

    test "ignores the request line even if it contains a colon" do
      headers = "GET /some:path HTTP/1.1\r\nHost: foo.example\r\n\r\n"
      assert Parser.extract_host(headers) == {:ok, "foo.example"}
    end
  end

  describe "subdomain/1" do
    test "returns the leftmost label" do
      assert Parser.subdomain("foo.example.com") == "foo"
    end

    test "lowercases the result" do
      assert Parser.subdomain("Foo.Example.Com") == "foo"
    end

    test "returns the whole string when there are no dots" do
      assert Parser.subdomain("localhost") == "localhost"
    end

    test "handles a single-label uppercase host" do
      assert Parser.subdomain("LOCALHOST") == "localhost"
    end
  end
end
