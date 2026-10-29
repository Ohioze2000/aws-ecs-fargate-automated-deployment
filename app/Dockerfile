# 1. Use a lightweight, pre-configured Nginx image
FROM nginx:stable-alpine

# 2. Set the working directory to where Nginx serves content
WORKDIR /usr/share/nginx/html

# 3. Clean out any default files
RUN rm -rf ./*

# 4. Copy your website files from your local folder to the container
# This assumes your index.html is in the same folder as this Dockerfile
COPY . .

# 5. Document that the container listens on port 80
EXPOSE 80

# 6. Start Nginx (The official image already has a CMD, but we can be explicit)
CMD ["nginx", "-g", "daemon off;"]