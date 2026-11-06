(() => {
  const config = window.NORTHWEAR_SUPABASE;
  const isConfigured = Boolean(config?.url && config?.anonKey);
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
    async placeOrder(items) {
      const client = await getClient();
      const { data, error } = await client.rpc("place_order", { p_items: items });

      if (error) throw error;
      return data;
    }
  };
})();
