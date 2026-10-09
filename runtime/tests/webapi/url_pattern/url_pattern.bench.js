// Collo-only.

bench("url-pattern.construct-pathname", (iterations) => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const pattern = new URLPattern({ pathname: "/users/:id/posts/:slug" });
    checksum += pattern.pathname.length;
  }
  return checksum;
});

bench("url-pattern.test-pathname-hit", (iterations) => {
  const pattern = new URLPattern({ pathname: "/users/:id/posts/:slug" });
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += pattern.test({ pathname: "/users/123/posts/hello" }) ? 1 : 0;
  return checksum;
});

bench("url-pattern.exec-pathname-groups", (iterations) => {
  const pattern = new URLPattern({ pathname: "/users/:id/posts/:slug" });
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const result = pattern.exec({ pathname: "/users/123/posts/hello" });
    checksum += result.pathname.groups.id.length + result.pathname.groups.slug.length;
  }
  return checksum;
});

bench("url-pattern.construct-absolute-ignore-case", (iterations) => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const pattern = new URLPattern("https://example.com/api/:version/*", { ignoreCase: true });
    checksum += pattern.protocol.length + pattern.hostname.length + pattern.pathname.length;
  }
  return checksum;
});

