FROM wordpress:latest

RUN echo "EnableMMAP Off" >> /etc/apache2/apache2.conf

RUN echo "EnableSendfile Off" >> /etc/apache2/apache2.conf

EXPOSE 80

CMD ["apache2-foreground"]
