(() => {
  const backend = window.northwearBackend;
  const authPanel = document.getElementById("auth-panel");
  const dashboard = document.getElementById("dashboard");
  const authForm = document.getElementById("auth-form");
  const productDialog = document.getElementById("product-dialog");
  const productForm = document.getElementById("product-form");
  const productRows = document.getElementById("product-rows");
  const toast = document.getElementById("toast");
  const categoryNames = {
    hoodie: "Худі",
    tee: "Футболки",
    pants: "Штани й шорти",
    jacket: "Куртки",
    other: "Інше"
  };
  const orderStatusNames = {
    new: "Нове",
    processing: "В роботі",
    completed: "Завершене",
    cancelled: "Скасоване"
  };
  const categoryThumbs = {
    hoodie: 'assets/channel-1299-1.jpg',
    tee: 'assets/channel-1285-2.jpg',
    pants: "assets/pants-default.jpg",
    jacket: 'assets/channel-1240-1.jpg',
    other: 'assets/channel-1299-3.jpg'
  };
  const garmentNames = {
    tee: "Футболка",
    hoodie: "Худі",
    sweatshirt: "Світшот"
  };
  const placementNames = {
    a6: "На грудях (A6)",
    front: "Спереду (A4)",
    back: "На спині (A4)"
  };
  const validCategories = new Set(Object.keys(categoryNames));
  const validOrderStatuses = new Set(Object.keys(orderStatusNames));
  let client;
  let currentUser;
  let currentRole;
  let currentProducts = [];
  let editingProduct;
  let signingUp = false;
  let toastTimer;
  let activeTab = "products";

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (character) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;"
    })[character]);
  }

  function setMessage(element, message, kind = "") {
    element.textContent = message;
    element.classList.toggle("is-error", kind === "error");
    element.classList.toggle("is-success", kind === "success");
  }

  function showToast(message) {
    toast.textContent = message;
    toast.classList.add("is-visible");
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => toast.classList.remove("is-visible"), 3200);
  }

  function formatPrice(price) {
    return new Intl.NumberFormat("uk-UA", {
      style: "currency",
      currency: "UAH",
      maximumFractionDigits: 2
    }).format(Number(price));
  }

  function formatDate(value) {
    const date = new Date(value);
    return Number.isNaN(date.getTime())
      ? "Дата невідома"
      : new Intl.DateTimeFormat("uk-UA", { dateStyle: "medium", timeStyle: "short" }).format(date);
  }

  function isHttpsUrl(value) {
    try {
      return new URL(value).protocol === "https:";
    } catch {
      return false;
    }
  }

  function showAuth(message = "", kind = "") {
    authPanel.classList.remove("is-hidden");
    dashboard.classList.add("is-hidden");
    document.getElementById("sign-out").classList.add("is-hidden");
    setMessage(document.getElementById("auth-message"), message, kind);
  }

  function renderAuthMode() {
    document.getElementById("auth-title").textContent = signingUp ? "Створення облікового запису" : "Кабінет магазину";
    document.getElementById("auth-submit").textContent = signingUp ? "Створити обліковий запис" : "Увійти";
    document.getElementById("auth-mode-toggle").textContent = signingUp
      ? "Повернутися до входу"
      : "Створити обліковий запис за запрошенням";
    document.getElementById("auth-hint").textContent = signingUp
      ? "Реєстрація доступна лише для пошти, яку адміністратор додав до запрошень."
      : "Новий працівник? Попроси адміністратора спочатку запросити твою робочу пошту.";
    document.getElementById("auth-password").autocomplete = signingUp ? "new-password" : "current-password";
  }

  async function loadProducts() {
    const { data, error } = await client
      .from("products")
      .select("id,name,category,tags,label,price,sizes,badge,image,alt,source,stock,is_active,updated_at")
      .order("updated_at", { ascending: false })
      .limit(1000);
    if (error) throw error;
    currentProducts = data || [];
    renderProducts();
  }

  function renderProducts() {
    const query = document.getElementById("product-search").value.trim().toLocaleLowerCase("uk");
    const includeArchived = document.getElementById("product-visibility").value === "all";
    const visibleProducts = currentProducts.filter((product) => {
      const activeMatches = includeArchived || product.is_active;
      const searchMatches = `${product.name} ${product.label} ${(product.tags || []).join(" ")}`
        .toLocaleLowerCase("uk")
        .includes(query);
      return activeMatches && searchMatches;
    });

    document.getElementById("product-count").textContent = `Товарів: ${visibleProducts.length}`;
    document.getElementById("products-empty").classList.toggle("is-hidden", visibleProducts.length > 0);
    productRows.innerHTML = visibleProducts.map((product) => `
      <tr>
        <td>
          <div class="product-cell">
            <img class="product-thumb" src="${escapeHtml(isHttpsUrl(product.image) && !product.image.includes('telesco.pe') ? product.image : (categoryThumbs[product.category] || 'assets/look-minimal.jpg'))}" alt="" loading="lazy" onerror="this.src='favicon.svg'">
            <strong title="${escapeHtml(product.name)}">${escapeHtml(product.name)}</strong>
          </div>
        </td>
        <td class="table-category">${escapeHtml(categoryNames[product.category] || product.category)}</td>
        <td>${product.price == null ? "Уточнити" : formatPrice(product.price)}</td>
        <td class="table-stock">${product.stock == null ? "—" : escapeHtml(product.stock)}</td>
        <td><span class="status-pill${product.is_active ? " is-active" : ""}">${product.is_active ? "Активний" : "Архів"}</span></td>
        <td>
          <div class="row-actions">
            <button class="small-button" type="button" data-product-action="edit" data-product-id="${escapeHtml(product.id)}">Змінити</button>
            <button class="small-button${product.is_active ? " is-archive" : ""}" type="button" data-product-action="toggle" data-product-id="${escapeHtml(product.id)}">${product.is_active ? "В архів" : "Відновити"}</button>
          </div>
        </td>
      </tr>
    `).join("");
  }

  async function loadOrders() {
    const message = document.getElementById("orders-message");
    setMessage(message, "");
    const { data, error } = await client
      .from("orders")
      .select("id,status,total_amount,customer_name,customer_phone,delivery_city,delivery_address,created_at,order_items(product_name,size,color,quantity,unit_price)")
      .order("created_at", { ascending: false })
      .limit(200);
    if (error) throw error;

    const orders = data || [];
    document.getElementById("orders-empty").classList.toggle("is-hidden", orders.length > 0);
    document.getElementById("orders-list").innerHTML = orders.map((order) => {
      const items = order.order_items || [];
      const status = validOrderStatuses.has(order.status) ? order.status : "new";
      return `
        <article class="order-card">
          <div class="order-heading">
            <div>
              <h3>Замовлення #${escapeHtml(order.id.slice(0, 8).toUpperCase())}</h3>
              <p class="order-date">${escapeHtml(formatDate(order.created_at))}</p>
            </div>
            <label class="visually-hidden" for="order-status-${escapeHtml(order.id)}">Статус замовлення</label>
            <select class="order-status" id="order-status-${escapeHtml(order.id)}" data-order-id="${escapeHtml(order.id)}">
              ${Object.entries(orderStatusNames).map(([value, name]) =>
                `<option value="${value}"${value === status ? " selected" : ""}>${name}</option>`
              ).join("")}
            </select>
          </div>
          <p class="order-date">
            Покупець: ${escapeHtml(order.customer_name || "—")} · ${escapeHtml(order.customer_phone || "—")}<br>
            Доставка: ${escapeHtml(order.delivery_city || "—")}, ${escapeHtml(order.delivery_address || "—")}
          </p>
          <ul class="order-items">
            ${items.map((item) => `
              <li>
                <span>${escapeHtml(item.product_name)} · ${escapeHtml(item.size)}${item.color ? ` · ${escapeHtml(item.color)}` : ""} × ${escapeHtml(item.quantity)}</span>
                <span>${formatPrice(item.unit_price * item.quantity)}</span>
              </li>
            `).join("")}
          </ul>
          <p class="order-total"><span>Разом</span><span>${formatPrice(order.total_amount)}</span></p>
        </article>
      `;
    }).join("");
  }

  async function loadCustomRequests() {
    const message = document.getElementById("custom-requests-message");
    setMessage(message, "");
    const { data, error } = await client
      .from("custom_requests")
      .select("id,status,customer_name,customer_phone,garment,garment_color,size,placement,print_text,quantity,image_path,created_at")
      .order("created_at", { ascending: false })
      .limit(200);
    if (error) throw error;

    const requests = await Promise.all((data || []).map(async (request) => {
      if (!request.image_path) return { ...request, imageUrl: "" };
      const { data: image, error: imageError } = await client.storage
        .from("custom-designs")
        .createSignedUrl(request.image_path, 3600);
      if (imageError) throw imageError;
      return { ...request, imageUrl: image.signedUrl };
    }));

    document.getElementById("custom-requests-empty").classList.toggle("is-hidden", requests.length > 0);
    document.getElementById("custom-requests-list").innerHTML = requests.map((request) => {
      const status = validOrderStatuses.has(request.status) ? request.status : "new";
      return `
        <article class="order-card">
          <div class="order-heading">
            <div>
              <h3>Заявка #${escapeHtml(request.id.slice(0, 8).toUpperCase())}</h3>
              <p class="order-date">${escapeHtml(formatDate(request.created_at))}</p>
            </div>
            <label class="visually-hidden" for="custom-request-status-${escapeHtml(request.id)}">Статус заявки</label>
            <select class="order-status" id="custom-request-status-${escapeHtml(request.id)}" data-custom-request-id="${escapeHtml(request.id)}">
              ${Object.entries(orderStatusNames).map(([value, name]) =>
                `<option value="${value}"${value === status ? " selected" : ""}>${name}</option>`
              ).join("")}
            </select>
          </div>
          <p class="order-date">
            Покупець: ${escapeHtml(request.customer_name)} · ${escapeHtml(request.customer_phone)}<br>
            Виріб: ${escapeHtml(garmentNames[request.garment] || request.garment)} · ${escapeHtml(request.garment_color)} · ${escapeHtml(request.size)}<br>
            Принт: ${escapeHtml(placementNames[request.placement] || request.placement)} · Кількість: ${escapeHtml(request.quantity)}
            ${request.print_text ? `<br>Текст: ${escapeHtml(request.print_text)}` : ""}
          </p>
          ${request.imageUrl ? `<p><a class="custom-design-link" href="${escapeHtml(request.imageUrl)}" target="_blank" rel="noopener noreferrer">Переглянути ескіз ↗</a></p>` : ""}
        </article>
      `;
    }).join("");
  }

  async function loadInvites() {
    if (currentRole !== "admin") return;
    const { data, error } = await client
      .from("staff_invites")
      .select("email,created_at")
      .order("created_at", { ascending: false });
    if (error) throw error;

    const invites = data || [];
    document.getElementById("invites-empty").classList.toggle("is-hidden", invites.length > 0);
    document.getElementById("invites-list").innerHTML = invites.map((invite) => `
      <li class="invite-row">
        <span>${escapeHtml(invite.email)} · ${escapeHtml(formatDate(invite.created_at))}</span>
        <button class="small-button is-archive" type="button" data-remove-invite="${escapeHtml(invite.email)}">Скасувати</button>
      </li>
    `).join("");
  }

  async function loadActiveTab() {
    try {
      if (activeTab === "products") await loadProducts();
      if (activeTab === "orders") await loadOrders();
      if (activeTab === "custom-requests") await loadCustomRequests();
      if (activeTab === "invites") await loadInvites();
    } catch (error) {
      const target = activeTab === "orders" ? "orders-message"
        : activeTab === "custom-requests" ? "custom-requests-message"
          : activeTab === "invites" ? "invites-message" : "import-message";
      setMessage(document.getElementById(target), `Не вдалося завантажити дані: ${error.message}`, "error");
    }
  }

  async function openDashboard(session) {
    if (!session?.user) return;
    if (currentUser?.id === session.user.id) return;
    currentUser = session.user;
    authPanel.classList.add("is-hidden");
    dashboard.classList.remove("is-hidden");
    document.getElementById("sign-out").classList.remove("is-hidden");
    document.getElementById("signed-in-as").textContent = session.user.email || "";

    const { data: role, error } = await client.rpc("current_staff_role");
    if (error) throw error;
    if (role !== "admin" && role !== "staff") {
      currentUser = null;
      await client.auth.signOut();
      showAuth("Для цієї пошти немає доступу. Попроси адміністратора надіслати запрошення.", "error");
      return;
    }

    currentRole = role;
    document.getElementById("role-badge").textContent = role === "admin" ? "Адміністратор" : "Працівник";
    document.getElementById("invites-tab").classList.toggle("is-hidden", role !== "admin");
    if (role !== "admin" && activeTab === "invites") activeTab = "products";
    setActiveTab(activeTab);
  }

  function setActiveTab(tabName) {
    activeTab = tabName;
    document.querySelectorAll("[data-tab]").forEach((button) => {
      const isActive = button.dataset.tab === tabName;
      button.classList.toggle("is-active", isActive);
      button.setAttribute("aria-selected", String(isActive));
    });
    document.querySelectorAll(".workspace").forEach((panel) => {
      panel.classList.toggle("is-hidden", panel.id !== `${tabName}-panel`);
    });
    void loadActiveTab();
  }

  function resetProductForm(product = null) {
    editingProduct = product;
    productForm.reset();
    setMessage(document.getElementById("product-form-message"), "");
    document.getElementById("product-dialog-title").textContent = product ? "Редагувати товар" : "Новий товар";
    document.getElementById("save-product").textContent = product ? "Зберегти зміни" : "Зберегти товар";
    if (!product) return;

    document.getElementById("product-name").value = product.name || "";
    document.getElementById("product-category").value = product.category;
    document.getElementById("product-price").value = product.price ?? "";
    document.getElementById("product-sizes").value = (product.sizes || []).join(", ");
    document.getElementById("product-stock").value = product.stock ?? "";
    document.getElementById("product-badge").value = product.badge || "";
    document.getElementById("product-label").value = product.label || "";
    document.getElementById("product-tags").value = (product.tags || []).join(", ");
    document.getElementById("product-image").value = product.image || "";
    document.getElementById("product-source").value = product.source || "";
  }

  async function saveProduct(event) {
    event.preventDefault();
    const submit = document.getElementById("save-product");
    const message = document.getElementById("product-form-message");
    const name = document.getElementById("product-name").value.trim();
    const sizes = [...new Set(document.getElementById("product-sizes").value.split(",").map((size) => size.trim()).filter(Boolean))];
    const tags = [...new Set(document.getElementById("product-tags").value.split(",").map((tag) => tag.trim().toLocaleLowerCase("en")).filter(Boolean))];
    const priceValue = document.getElementById("product-price").value.trim();
    const stockValue = document.getElementById("product-stock").value.trim();
    const imageInput = document.getElementById("product-image");
    const file = document.getElementById("product-image-file").files[0];
    const source = document.getElementById("product-source").value.trim();

    if (!name || sizes.length === 0) {
      setMessage(message, "Вкажи назву товару та щонайменше один розмір.", "error");
      return;
    }
    if (priceValue && (!Number.isFinite(Number(priceValue)) || Number(priceValue) < 0)) {
      setMessage(message, "Ціна має бути невід'ємним числом.", "error");
      return;
    }
    if (stockValue && (!Number.isInteger(Number(stockValue)) || Number(stockValue) < 0)) {
      setMessage(message, "Залишок має бути цілим невід'ємним числом.", "error");
      return;
    }
    if (tags.some((tag) => !/^[a-z0-9_-]+$/.test(tag))) {
      setMessage(message, "Теги мають містити лише латинські літери, цифри, дефіс або підкреслення.", "error");
      return;
    }
    if (!file && !isHttpsUrl(imageInput.value.trim())) {
      setMessage(message, "Додай безпечне посилання на фото (HTTPS) або завантаж файл.", "error");
      return;
    }
    if (file && (!["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 8_000_000)) {
      setMessage(message, "Підтримуються JPEG, PNG та WebP розміром до 8 МБ.", "error");
      return;
    }
    if (source && !isHttpsUrl(source)) {
      setMessage(message, "Посилання на пост має використовувати HTTPS.", "error");
      return;
    }

    submit.disabled = true;
    setMessage(message, "");
    try {
      let image = imageInput.value.trim();
      if (file) {
        const extension = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" }[file.type];
        const path = `${currentUser.id}/${crypto.randomUUID()}.${extension}`;
        const { error: uploadError } = await client.storage
          .from("product-images")
          .upload(path, file, { cacheControl: "3600", contentType: file.type, upsert: false });
        if (uploadError) throw uploadError;
        image = client.storage.from("product-images").getPublicUrl(path).data.publicUrl;
      }

      const product = {
        id: editingProduct?.id || `nw-${crypto.randomUUID()}`,
        name,
        category: document.getElementById("product-category").value,
        tags,
        label: document.getElementById("product-label").value.trim(),
        price: priceValue ? Number(priceValue) : null,
        sizes,
        badge: document.getElementById("product-badge").value.trim(),
        image,
        alt: `Фото товару: ${name}`,
        source,
        stock: stockValue ? Number(stockValue) : null,
        is_active: editingProduct?.is_active ?? true,
        updated_at: new Date().toISOString()
      };
      const { error } = await client.from("products").upsert(product, { onConflict: "id" });
      if (error) throw error;

      productDialog.close();
      await loadProducts();
      showToast(editingProduct ? "Зміни збережено." : "Товар додано до каталогу.");
    } catch (error) {
      setMessage(message, `Не вдалося зберегти товар: ${error.message}`, "error");
    } finally {
      submit.disabled = false;
    }
  }

  function validateSeedProducts(products) {
    if (!Array.isArray(products) || products.length === 0 || products.length > 1000) {
      throw new Error("Файл має містити масив із 1–1000 товарів.");
    }
    const ids = new Set();
    for (const product of products) {
      if (!product || typeof product.id !== "string" || !product.id || ids.has(product.id)) {
        throw new Error("У файлі є товар без унікального ідентифікатора.");
      }
      ids.add(product.id);
      if (typeof product.name !== "string" || !product.name.trim() || !validCategories.has(product.category)) {
        throw new Error(`Перевір назву та категорію товару ${product.id}.`);
      }
      if (!isHttpsUrl(product.image) || !Array.isArray(product.sizes) || product.sizes.length === 0) {
        throw new Error(`Перевір фото та розміри товару ${product.name}.`);
      }
      if (product.price != null && (!Number.isFinite(Number(product.price)) || Number(product.price) < 0)) {
        throw new Error(`Перевір ціну товару ${product.name}.`);
      }
      if (!Array.isArray(product.tags || []) || !Array.isArray(product.sizes)) {
        throw new Error(`Перевір теги та розміри товару ${product.name}.`);
      }
    }
  }

  async function importCatalog(file) {
    const message = document.getElementById("import-message");
    try {
      const products = JSON.parse(await file.text());
      validateSeedProducts(products);
      if (!window.confirm(`Імпортувати ${products.length} товарів? Існуючі товари з такими ID оновляться.`)) return;

      const importButton = document.getElementById("import-products");
      importButton.disabled = true;
      setMessage(message, `Імпортовано 0 із ${products.length}...`);
      try {
        for (let index = 0; index < products.length; index += 100) {
          const batch = products.slice(index, index + 100).map(({ is_active, ...product }) => product);
          const { error } = await client.from("products").upsert(batch, { onConflict: "id" });
          if (error) throw new Error(`Пакет ${Math.floor(index / 100) + 1}, виконано ${index} товарів: ${error.message}`);
          setMessage(message, `Імпортовано ${Math.min(index + batch.length, products.length)} із ${products.length}...`);
        }
        await loadProducts();
        setMessage(message, `Готово: імпортовано ${products.length} товарів.`, "success");
      } finally {
        importButton.disabled = false;
      }
    } catch (error) {
      setMessage(message, `Імпорт не завершено: ${error.message}`, "error");
    }
  }

  async function toggleProduct(product) {
    const nextActive = !product.is_active;
    const { error } = await client
      .from("products")
      .update({ is_active: nextActive, updated_at: new Date().toISOString() })
      .eq("id", product.id);
    if (error) throw error;
    await loadProducts();
    showToast(nextActive ? "Товар повернуто до каталогу." : "Товар переміщено в архів.");
  }

  async function changeOrderStatus(select) {
    const orderId = select.dataset.orderId;
    const nextStatus = select.value;
    if (!validOrderStatuses.has(nextStatus)) return;
    select.disabled = true;
    try {
      const { error } = await client
        .from("orders")
        .update({ status: nextStatus, updated_at: new Date().toISOString() })
        .eq("id", orderId);
      if (error) throw error;
      showToast("Статус замовлення оновлено.");
    } catch (error) {
      setMessage(document.getElementById("orders-message"), `Не вдалося змінити статус: ${error.message}`, "error");
      await loadOrders();
    } finally {
      select.disabled = false;
    }
  }

  async function changeCustomRequestStatus(select) {
    const requestId = select.dataset.customRequestId;
    const nextStatus = select.value;
    if (!validOrderStatuses.has(nextStatus)) return;
    select.disabled = true;
    try {
      const { error } = await client
        .from("custom_requests")
        .update({ status: nextStatus, updated_at: new Date().toISOString() })
        .eq("id", requestId);
      if (error) throw error;
      showToast("Статус заявки оновлено.");
    } catch (error) {
      let message = `Не вдалося змінити статус: ${error.message}`;
      try {
        await loadCustomRequests();
      } catch (refreshError) {
        message += ` Не вдалося оновити список: ${refreshError.message}`;
      }
      setMessage(document.getElementById("custom-requests-message"), message, "error");
    } finally {
      select.disabled = false;
    }
  }

  async function inviteStaff(event) {
    event.preventDefault();
    const input = document.getElementById("invite-email");
    const email = input.value.trim().toLocaleLowerCase("en");
    const message = document.getElementById("invites-message");
    setMessage(message, "");
    const { error } = await client.from("staff_invites").insert({
      email,
      role: "staff",
      invited_by: currentUser.id
    });
    if (error) {
      setMessage(message, `Не вдалося запросити працівника: ${error.message}`, "error");
      return;
    }
    input.value = "";
    setMessage(message, "Запрошення створено. Працівник може зареєструватися з цією поштою.", "success");
    await loadInvites();
  }

  async function removeInvite(email) {
    const { error } = await client.from("staff_invites").delete().eq("email", email);
    if (error) {
      setMessage(document.getElementById("invites-message"), `Не вдалося скасувати запрошення: ${error.message}`, "error");
      return;
    }
    await loadInvites();
    showToast("Запрошення скасовано.");
  }

  async function handleAuthChange(session) {
    if (!session) {
      currentUser = null;
      currentRole = null;
      showAuth();
      return;
    }
    try {
      await openDashboard(session);
    } catch (error) {
      currentUser = null;
      await client.auth.signOut();
      showAuth(`Не вдалося відкрити кабінет: ${error.message}`, "error");
    }
  }

  document.getElementById("auth-mode-toggle").addEventListener("click", () => {
    signingUp = !signingUp;
    setMessage(document.getElementById("auth-message"), "");
    renderAuthMode();
  });

  authForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!client) return;
    const submit = document.getElementById("auth-submit");
    const email = document.getElementById("auth-email").value.trim().toLocaleLowerCase("en");
    const password = document.getElementById("auth-password").value;
    submit.disabled = true;
    setMessage(document.getElementById("auth-message"), "");
    try {
      if (signingUp) {
        const { data, error } = await client.auth.signUp({
          email,
          password,
          options: { emailRedirectTo: new URL("staff.html", window.location.href).href }
        });
        if (error) throw error;
        if (data.session) {
          setMessage(document.getElementById("auth-message"), "Обліковий запис створено. Відкриваємо кабінет...", "success");
        } else {
          signingUp = false;
          renderAuthMode();
          setMessage(document.getElementById("auth-message"), "Перевір пошту та підтверди адресу, потім увійди до кабінету.", "success");
        }
      } else {
        const { error } = await client.auth.signInWithPassword({ email, password });
        if (error) throw error;
      }
    } catch (error) {
      setMessage(document.getElementById("auth-message"), `Не вдалося виконати запит: ${error.message}`, "error");
    } finally {
      submit.disabled = false;
    }
  });

  document.getElementById("sign-out").addEventListener("click", async () => {
    const { error } = await client.auth.signOut();
    if (error) showToast(`Не вдалося вийти: ${error.message}`);
  });

  document.querySelectorAll("[data-tab]").forEach((button) => {
    button.addEventListener("click", () => setActiveTab(button.dataset.tab));
  });
  document.getElementById("product-search").addEventListener("input", renderProducts);
  document.getElementById("product-visibility").addEventListener("change", renderProducts);
  document.getElementById("add-product").addEventListener("click", () => {
    resetProductForm();
    productDialog.showModal();
  });
  document.getElementById("close-product-dialog").addEventListener("click", () => productDialog.close());
  document.getElementById("cancel-product").addEventListener("click", () => productDialog.close());
  productDialog.addEventListener("click", (event) => {
    if (event.target === productDialog) productDialog.close();
  });
  productForm.addEventListener("submit", saveProduct);

  productRows.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-product-action]");
    if (!button) return;
    const product = currentProducts.find((item) => item.id === button.dataset.productId);
    if (!product) return;
    if (button.dataset.productAction === "edit") {
      resetProductForm(product);
      productDialog.showModal();
      return;
    }
    button.disabled = true;
    try {
      await toggleProduct(product);
    } catch (error) {
      setMessage(document.getElementById("import-message"), `Не вдалося оновити товар: ${error.message}`, "error");
    } finally {
      button.disabled = false;
    }
  });

  document.getElementById("import-products").addEventListener("click", () => {
    document.getElementById("import-file").click();
  });
  document.getElementById("import-file").addEventListener("change", (event) => {
    const file = event.target.files[0];
    event.target.value = "";
    if (file) void importCatalog(file);
  });
  document.getElementById("refresh-orders").addEventListener("click", () => void loadOrders());
  document.getElementById("refresh-custom-requests").addEventListener("click", () => {
    void loadCustomRequests().catch((error) => {
      setMessage(document.getElementById("custom-requests-message"), `Не вдалося завантажити заявки: ${error.message}`, "error");
    });
  });
  document.getElementById("orders-list").addEventListener("change", (event) => {
    if (event.target.matches("[data-order-id]")) void changeOrderStatus(event.target);
  });
  document.getElementById("custom-requests-list").addEventListener("change", (event) => {
    if (event.target.matches("[data-custom-request-id]")) void changeCustomRequestStatus(event.target);
  });
  document.getElementById("invite-form").addEventListener("submit", inviteStaff);
  document.getElementById("invites-list").addEventListener("click", (event) => {
    const button = event.target.closest("[data-remove-invite]");
    if (button) void removeInvite(button.dataset.removeInvite);
  });

  renderAuthMode();
  if (!backend?.isConfigured) {
    const setupNote = document.getElementById("setup-note");
    setupNote.textContent = "Онлайн-кабінет ще не підключено. Заповни Project URL і публічний anon key у supabase-config.js та виконай інструкції з README.md.";
    setupNote.classList.remove("is-hidden");
    document.getElementById("auth-submit").disabled = true;
    document.getElementById("auth-mode-toggle").disabled = true;
  } else {
    void (async () => {
      try {
        client = await backend.getClient();
        client.auth.onAuthStateChange((_event, session) => {
          window.setTimeout(() => void handleAuthChange(session), 0);
        });
        const { data, error } = await client.auth.getSession();
        if (error) throw error;
        await handleAuthChange(data.session);
      } catch (error) {
        showAuth(`Не вдалося підключитися до кабінету: ${error.message}`, "error");
      }
    })();
  }
})();
