(() => {
  const config = window.NORTHWEAR_SUPABASE;
  let isConfigured = false;
  if (typeof config?.url === "string" && config.url.trim()
    && typeof config.anonKey === "string" && config.anonKey.trim()) {
    try {
      isConfigured = new URL(config.url).protocol === "https:";
    } catch {
      isConfigured = false;
    }
  }
  let clientPromise;

  function getClient() {
    if (!isConfigured) {
      return Promise.reject(new Error("Спочатку налаштуйте Supabase у файлі supabase-config.js."));
    }

    if (!clientPromise) {
      clientPromise = new Promise((resolve, reject) => {
        const script = document.createElement("script");
        script.src = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2";
        script.async = true;
        script.onload = () => {
          if (!window.supabase?.createClient) {
            reject(new Error("Не вдалося завантажити бібліотеку Supabase."));
            return;
          }

          resolve(window.supabase.createClient(config.url, config.anonKey, {
            auth: {
              autoRefreshToken: true,
              detectSessionInUrl: true,
              persistSession: true
            }
          }));
        };
        script.onerror = () => reject(new Error("Не вдалося завантажити Supabase. Перевірте підключення до інтернету."));
        document.head.appendChild(script);
      });
    }

    return clientPromise;
  }

  window.northwearBackend = {
    isConfigured,
    getClient,
    async loadProducts() {
      const client = await getClient();
      const { data, error } = await client
        .from("products")
        .select("id,name,category,tags,label,price,sizes,badge,image,alt,source,stock")
        .eq("is_active", true)
        .order("created_at", { ascending: false });

      if (error) throw error;
      return data;
    },
    async loadPopularProducts() {
      const client = await getClient();
      const { data, error } = await client.rpc("popular_products");

      if (error) throw error;
      return data;
    },
    async placeOrder(items, customer) {
      const client = await getClient();
      const { data, error } = await client.rpc("place_order", {
        p_items: items,
        p_customer: customer
      });

      if (error) throw error;
      return data;
    },
    async createCustomRequest(request, file) {
      const client = await getClient();
      const id = crypto.randomUUID();
      let imagePath = null;

      if (file) {
        const extensions = {
          "image/jpeg": "jpg",
          "image/png": "png",
          "image/webp": "webp"
        };
        const extension = extensions[file.type];
        if (!extension || file.size > 8000000) {
          throw new Error("Оберіть JPG, PNG або WebP розміром до 8 МБ.");
        }

        imagePath = `${id}/design.${extension}`;
        const { error } = await client.storage
          .from("custom-designs")
          .upload(imagePath, file, { contentType: file.type, upsert: false });
        if (error) throw error;
      }

      const { error } = await client.from("custom_requests").insert({
        id,
        ...request,
        image_path: imagePath
      });
      if (error) throw error;
      return { id };
    }
  };
})();
